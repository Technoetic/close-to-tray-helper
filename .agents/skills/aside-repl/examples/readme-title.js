const tab = await openTab('about:blank');
try {
  await tab.goto('https://github.com/Technoetic/close-to-tray-helper');
  const deadline = Date.now() + 15000;
  let heading;
  while (!heading && Date.now() < deadline) {
    heading = await tab.evaluate(() => document.querySelector('article h1')?.textContent.trim());
    if (!heading) await new Promise(resolve => setTimeout(resolve, 250));
  }
  if (!heading) throw new Error('README heading was not found.');
  console.log(JSON.stringify({ heading }));
} finally {
  await closeTab(tab);
}
