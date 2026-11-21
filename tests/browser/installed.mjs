// Only a missing Playwright or browser skips a test (exit 1), and only a
// library the machine lacks skips one browser; any other failure to start
// a browser must fail the test.
const [test, ...names] = process.argv.slice(2);
let playwright;
try {
  playwright = (await import("./playwright.mjs")).default;
} catch (e) {
  if (e.code === "MODULE_NOT_FOUND") process.exit(1);
  console.error(e);
  process.exit(2);
}
const usable = [];
for (const name of names) {
  let browser;
  try {
    browser = await playwright[name].launch();
  } catch (e) {
    if (/Executable doesn't exist/.test(e.message)) process.exit(1);
    const lacks = e.message.match(/error while loading shared libraries: (\S+):/);
    if (lacks) {
      console.error(`${test}: skipped ${name}: this machine lacks ${lacks[1]}`);
      continue;
    }
    console.error(e);
    process.exit(2);
  }
  await browser.close();
  usable.push(name);
}
console.log(usable.join(" "));
