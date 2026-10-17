// Spawns the helper and sends IsReady, GetAccessibilityStatus and GetHardwareInfo.
// Usage: node ipc-smoke.js "/path/to/Murmur.app/Contents/MacOS/Murmur"
const { spawn } = require("child_process");
const esc = (s) => s.replace(/\+/g, "+1").replace(/\|/g, "+2");
const unesc = (s) => s.replace(/\+([12])/g, (_, d) => (d === "1" ? "+" : "|"));

const child = spawn(process.argv[2], [], { stdio: ["pipe", "pipe", "pipe", "pipe"] });
child.stderr.on("data", (d) => process.stderr.write(d));
let buf = "";
child.stdio[3].on("data", (d) => {
  buf += d.toString("utf8");
  let i;
  while ((i = buf.indexOf("|")) >= 0) {
    console.log("<-", unesc(buf.slice(0, i)));
    buf = buf.slice(i + 1);
  }
});
const send = (name, value) =>
  child.stdin.write(esc(JSON.stringify({ HelperAPIRequest: { uuid: String(Math.random()), [name]: value } })) + "|");

send("IsReady", true);
send("GetAccessibilityStatus", true);
send("GetHardwareInfo", true);
send("Bogus", true); // expect HelperAPIError NO_HANDLER_REGISTERED
setTimeout(() => {
  send("HelperAppShutdown", true);
  setTimeout(() => process.exit(0), 500);
}, 1500);
