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
<iframe id="child" src="http://${host}:${childPort}/child"></iframe>
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
	await page.evaluate(() => window.reworkerTest.connect())

	assert(await page.evaluate(() => window.reworkerTest.ping("hello")) === "child:hello", "typed request failed")
	assert(await page.evaluate(() => window.reworkerTest.reverse("hello")) === "parent:hello", "reverse request failed")

	await page.evaluate(() => window.reworkerTest.cast("notice"))
	await page.waitForFunction(async () => await window.reworkerTest.notice() === "notice")

	const remoteError = await page.evaluate(async () => {
		try { await window.reworkerTest.fail(); return "resolved" } catch (error) { return String(error) }
	})
	assert(remoteError.includes("Child handler failed"), "remote error did not reject")

	const timeoutError = await page.evaluate(async () => {
		try { await window.reworkerTest.timeout(); return "resolved" } catch (error) { return String(error) }
	})
	assert(timeoutError.includes("Request timed out"), "request timeout did not reject")

	const cloneError = await page.evaluate(async () => {
		try { await window.reworkerTest.uncloneable(); return "resolved" } catch (error) { return String(error) }
	})
	assert(cloneError !== "resolved", "structured clone failure did not reject")
	assert(await page.evaluate(() => window.reworkerTest.large()), "chunked request failed")

	const reloadError = await page.evaluate(async () => {
		const pending = window.reworkerTest.timeout()
		document.querySelector("iframe").src += "?reload=1"
		try { await pending; return "resolved" } catch (error) { return String(error) }
	})
	assert(reloadError.includes("Iframe reloaded"), "iframe reload did not reject pending request")
	await page.waitForFunction(() => window.reworkerTest.isOpen())
	assert(await page.evaluate(() => window.reworkerTest.ping("again")) === "child:again", "reload did not reconnect")

	const closeError = await page.evaluate(async () => {
		const pending = window.reworkerTest.timeout()
		window.reworkerTest.close()
		try { await pending; return "resolved" } catch (error) { return String(error) }
	})
	assert(closeError.includes("Runtime closed"), "teardown did not reject pending request")

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
