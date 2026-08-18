import {createServer} from "node:http"
import {mkdtemp, readFile, rm} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {build} from "esbuild"
import {chromium} from "playwright"

const host = "127.0.0.1"
const parentPort = 4173
const childPort = 4174
const attackerPort = 4175
const outputDirectory = await mkdtemp(join(tmpdir(), "reworker-browser-"))

const assert = (condition, message) => {
	if (!condition) {
		throw new Error(message)
	}
}

const listen = (port, render) => new Promise(resolve => {
	const server = createServer((request, response) => {
		const body = render(request.url)
		response.writeHead(body === undefined ? 404 : 200, {
			"content-type": request.url.endsWith(".js") ? "text/javascript" : "text/html",
		})
		response.end(body ?? "Not found")
	})
	server.listen(port, host, () => resolve(server))
})

const closeServer = server => new Promise((resolve, reject) => {
	server.close(error => error === undefined ? resolve() : reject(error))
})

const childHtml = `<!doctype html><script type="module" src="/child.js"></script>`
const parentHtml = `<!doctype html>
<script>
window.portListenerRemoves = 0
window.portMessagePosts = 0
const removePortListener = MessagePort.prototype.removeEventListener
const postPortMessage = MessagePort.prototype.postMessage
MessagePort.prototype.removeEventListener = function(...args) {
	window.portListenerRemoves += 1
	return removePortListener.apply(this, args)
}
MessagePort.prototype.postMessage = function(...args) {
	window.portMessagePosts += 1
	return postPortMessage.apply(this, args)
}
</script>
<iframe id="child-a" src="http://${host}:${childPort}/child"></iframe>
<iframe id="child-b" src="http://${host}:${childPort}/child"></iframe>
<iframe id="child-c" src="http://${host}:${childPort}/child"></iframe>
<iframe id="child-d" src="http://${host}:${childPort}/child"></iframe>
<script type="module" src="/parent.js"></script>`
const wrongOriginHtml = `<!doctype html>
<iframe id="child" src="http://${host}:${childPort}/child"></iframe>
<script>
window.attackReady = false
document.querySelector("iframe").addEventListener("load", () => {
	const channel = new MessageChannel()
	channel.port1.onmessage = () => { window.attackReady = true }
	document.querySelector("iframe").contentWindow.postMessage({
		marker: "@bluehotdog/reworker/window/v1",
		kind: "connect",
		channel: "main",
		connectionId: "wrong-origin",
	}, "http://${host}:${childPort}", [channel.port2])
})
</script>`
const wrongSourceHtml = `<!doctype html>
<iframe name="target" src="http://${host}:${childPort}/child"></iframe>
<iframe name="sender" src="/sender"></iframe>
<script>
window.attackReady = false
let loaded = 0
for (const frame of document.querySelectorAll("iframe")) {
	frame.addEventListener("load", () => {
		loaded += 1
		if (loaded === 2) frames.sender.forge(frames.target)
	})
}
</script>`
const senderHtml = `<!doctype html><script>
window.forge = target => {
	const channel = new MessageChannel()
	channel.port1.onmessage = () => { parent.attackReady = true }
	target.postMessage({
		marker: "@bluehotdog/reworker/window/v1",
		kind: "connect",
		channel: "main",
		connectionId: "wrong-source",
	}, "http://${host}:${childPort}", [channel.port2])
}
</script>`

let browser
let servers = []

try {
	await build({
		entryPoints: ["src/WindowTransportParent__test.res.mjs"],
		bundle: true,
		format: "esm",
		outfile: join(outputDirectory, "parent.js"),
	})
	await build({
		entryPoints: ["src/WindowTransportChild__test.res.mjs"],
		bundle: true,
		format: "esm",
		outfile: join(outputDirectory, "child.js"),
	})

	const parentBundle = await readFile(join(outputDirectory, "parent.js"))
	const childBundle = await readFile(join(outputDirectory, "child.js"))
	servers = await Promise.all([
		listen(parentPort, path => {
			if (path === "/parent.js") return parentBundle
			if (path === "/sender") return senderHtml
			if (path === "/wrong-source") return wrongSourceHtml
			return parentHtml
		}),
		listen(childPort, path => path === "/child.js" ? childBundle : childHtml),
		listen(attackerPort, () => wrongOriginHtml),
	])

	browser = await chromium.launch({headless: true})
	const page = await browser.newPage()
	await page.goto(`http://${host}:${parentPort}`)
	await page.waitForFunction(() => window.reworkerTest !== undefined)
	const invalidParentOrigin = await page.evaluate(async () => {
		try { await window.reworkerTest.invalidOrigin("*"); return "resolved" } catch (error) { return String(error) }
	})
	assert(invalidParentOrigin.includes("explicit origin"), "parent accepted wildcard origin")
	const invalidChannel = await page.evaluate(async () => {
		try { await window.reworkerTest.invalidChannel(); return "resolved" } catch (error) { return String(error) }
	})
	assert(invalidChannel.includes("channel"), "parent accepted empty channel")
	const childFrame = page.frames().find(frame => frame.url().includes(`:${childPort}`))
	assert(childFrame !== undefined, "child frame was not found")
	await childFrame.waitForFunction(() => window.reworkerChildTest !== undefined)
	const invalidChildOrigin = await childFrame.evaluate(async () => {
		try { await window.reworkerChildTest.invalidOrigin(""); return "resolved" } catch (error) { return String(error) }
	})
	assert(invalidChildOrigin.includes("explicit origin"), "child accepted empty origin")
	assert(await childFrame.evaluate(() => window.reworkerChildTest.sessionIsolation()), "private handshake ID leaked or stale session affected replacement")
	await page.waitForFunction(() => window.reworkerTest.allOpen())
	assert(JSON.stringify(await page.evaluate(() => window.reworkerTest.lifecycleCounts())) === JSON.stringify([1, 1, 0]), "initial replacement lifecycle events were incorrect")
	await page.waitForFunction(() => window.reworkerTest.childOpenNotices() === 2)
	assert(await page.evaluate(() => window.reworkerTest.pingIsolated("channel")) === "secondary:channel", "same-window child channel isolation failed")
	await page.waitForFunction(() => window.reworkerTest.staleOpen())
	await page.waitForTimeout(250)
	assert(await page.evaluate(() => window.reworkerTest.staleOpen()), "stale readiness timeout closed replacement connection")
	assert(await page.evaluate(() => window.reworkerTest.pingStale("initial-load")) === "secondary:initial-load", "initial load replacement did not connect")
	assert(await page.evaluate(() => window.reworkerTest.closeDuringReplacement()), "close during disconnected replacement reopened runtime")

	assert(await page.evaluate(() => window.reworkerTest.ping("hello")) === "child:hello", "typed request failed")
	assert(await page.evaluate(() => window.reworkerTest.reverse("hello")) === "parent:hello", "reverse request failed")
	const preCancelledError = await page.evaluate(async () => {
		try { await window.reworkerTest.preCancelled(); return "resolved" } catch (error) { return String(error) }
	})
	assert(preCancelledError.includes("Request aborted"), "pre-aborted request did not reject")
	assert(await page.evaluate(() => window.reworkerTest.cancellationCount()) === 0, "pre-aborted request reached remote handler")
	assert(await page.evaluate(() => window.reworkerTest.cancellationStartCount()) === 0, "pre-aborted request started remote handler")
	const cancellationError = await page.evaluate(async () => {
		try { await window.reworkerTest.cancel(); return "resolved" } catch (error) { return String(error) }
	})
	assert(cancellationError.includes("Request aborted"), "in-flight cancellation did not reject")
	await page.waitForFunction(async () => await window.reworkerTest.cancellationCount() === 1)
	assert(await page.evaluate(() => window.reworkerTest.cancellationStartCount()) === 1, "in-flight request did not start exactly once")
	const frameResponses = await page.evaluate(() => Promise.all([
		window.reworkerTest.pingFrame(0, "first"),
		window.reworkerTest.pingFrame(1, "second"),
	]))
	assert(frameResponses[0] === "child:first", "first iframe runtime failed")
	assert(frameResponses[1] === "child:second", "second iframe runtime failed")

	await page.evaluate(() => window.reworkerTest.cast("notice"))
	await page.waitForFunction(async () => await window.reworkerTest.notice() === "notice")

	const remoteError = await page.evaluate(async () => {
		try { await window.reworkerTest.fail(); return "resolved" } catch (error) { return String(error) }
	})
	assert(remoteError.includes("Child handler failed"), "remote error did not reject")

	const timeoutError = await page.evaluate(async () => {
		try { await window.reworkerTest.timeout(); return "resolved" } catch (error) { return String(error) }
	})
	assert(timeoutError.includes("timed out"), `request timeout did not reject: ${timeoutError}`)

	assert(await page.evaluate(() => window.reworkerTest.large()), "chunked request failed")
	const oversizedError = await page.evaluate(async () => {
		try { await window.reworkerTest.oversized(); return "resolved" } catch (error) { return String(error) }
	})
	assert(oversizedError.includes("maxMessageBytes"), "oversized message was not rejected")

	const reloadError = await page.evaluate(async () => {
		const pending = window.reworkerTest.delayedReverse("old-generation")
		document.querySelector("#child-a").src += "?reload=1"
		try { await pending; return "resolved" } catch (error) { return String(error) }
	})
	assert(reloadError.includes("unloading") || reloadError.includes("Iframe reloaded"), "iframe reload did not reject pending request")
	await page.waitForFunction(() => window.reworkerTest.isOpen())
	assert(JSON.stringify(await page.evaluate(() => window.reworkerTest.lifecycleCounts())) === JSON.stringify([2, 2, 0]), "reconnect lifecycle events were incorrect")
	assert(await page.evaluate(() => window.reworkerTest.ping("again")) === "child:again", "reload did not reconnect")
	assert(await page.evaluate(() => window.reworkerTest.pingFrame(1, "unaffected")) === "child:unaffected", "reload affected another iframe runtime")

	const closeResult = await page.evaluate(async () => {
		const pending = window.reworkerTest.timeout()
		const removalsBefore = window.portListenerRemoves
		window.reworkerTest.close()
		try {
			await pending
			return {error: "resolved", removedListeners: window.portListenerRemoves - removalsBefore}
		} catch (error) {
			return {error: String(error), removedListeners: window.portListenerRemoves - removalsBefore}
		}
	})
	assert(closeResult.error.includes("Runtime closed"), "teardown did not reject pending request")
	assert(closeResult.removedListeners === 2, "idempotent teardown did not remove port listeners exactly once")
	assert(JSON.stringify(await page.evaluate(() => window.reworkerTest.lifecycleCounts())) === JSON.stringify([2, 2, 1]), "terminal close lifecycle event was incorrect")
	assert(await page.evaluate(() => window.reworkerTest.firstLoadListenersRemoved()), "load listener was not removed")
	assert(await page.evaluate(() => window.reworkerTest.pingFrame(1, "still-open")) === "child:still-open", "closing one runtime affected another")
	const wrongOriginPage = await browser.newPage()
	await wrongOriginPage.goto(`http://${host}:${attackerPort}`)
	await wrongOriginPage.waitForTimeout(700)
	assert(!await wrongOriginPage.evaluate(() => window.attackReady), "incorrect origin was accepted")

	const wrongSourcePage = await browser.newPage()
	await wrongSourcePage.goto(`http://${host}:${parentPort}/wrong-source`)
	await wrongSourcePage.waitForTimeout(700)
	assert(!await wrongSourcePage.evaluate(() => window.attackReady), "incorrect source window was accepted")

	console.log("Window transport browser tests passed")
} finally {
	if (browser !== undefined) await browser.close()
	await Promise.all(servers.map(closeServer))
	await rm(outputDirectory, {recursive: true, force: true})
}
