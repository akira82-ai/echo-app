// Local clipboard conversion adapter. Turndown 7.2.0 + GFM 1.0.2 (MIT).
function convertClipboardHTML(html) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  doc.querySelectorAll('script,style,iframe,object,embed,link,meta').forEach(node => {
    // Preserve inline CSS information below; do not execute or load source assets.
    if (node.tagName !== 'STYLE') node.remove();
  });

  // AppKit's HTML exporter uses CSS classes, rather than semantic <strong>/<em>.
  // Inspect declared rules in the detached document, without rendering the source.
  const styles = [];
  doc.querySelectorAll('style').forEach(node => {
    const sheet = new CSSStyleSheet();
    try { sheet.replaceSync(node.textContent); }
    catch (error) { throw new Error('Cannot parse source stylesheet: ' + error.message); }
    for (const rule of sheet.cssRules) {
      if (rule.selectorText && rule.style) styles.push(rule);
    }
    node.remove();
  });
  const service = new TurndownService({headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-', emDelimiter: '*'});
  service.use(turndownPluginGfm.gfm);
  // Turndown clones its input DOM, so style metadata must survive cloning.
  doc.body.querySelectorAll('*').forEach(node => {
    const values = {};
    const apply = style => {
      for (const property of ['font-weight', 'font-style', 'text-decoration', 'text-decoration-line']) {
        if (style.getPropertyValue(property)) values[property] = style.getPropertyValue(property);
      }
      // CSSOM expands font shorthand, including AppKit's "font: ..." output.
      if (style.fontWeight) values['font-weight'] = style.fontWeight;
      if (style.fontStyle) values['font-style'] = style.fontStyle;
    };
    for (const rule of styles) {
      try { if (node.matches(rule.selectorText)) apply(rule.style); }
      catch (_) { /* Unsupported selectors do not describe a supported style. */ }
    }
    apply(node.style);
    node.setAttribute('data-echo-format', JSON.stringify(values));
  });
  service.addRule('clipboard-css-formatting', {
    filter: node => {
      const s = JSON.parse(node.getAttribute('data-echo-format') || '{}');
      return ['SPAN', 'P', 'DIV', 'A'].includes(node.nodeName) && s &&
        (s['font-weight'] === 'bold' || Number(s['font-weight']) >= 600 || s['font-style'] === 'italic' || /line-through/.test(s['text-decoration'] || s['text-decoration-line'] || ''));
    },
    replacement: (content, node) => {
      if (!content.trim()) return content;
      const s = JSON.parse(node.getAttribute('data-echo-format') || '{}');
      let text = content.trim();
      if (s['font-weight'] === 'bold' || Number(s['font-weight']) >= 600) text = '**' + text + '**';
      if (s['font-style'] === 'italic') text = '*' + text + '*';
      if (/line-through/.test(s['text-decoration'] || s['text-decoration-line'] || '')) text = '~~' + text + '~~';
      if (node.nodeName === 'A' && node.getAttribute('href')) {
        text = '[' + text + '](' + node.getAttribute('href').replace(/\)/g, '\\)') + ')';
      }
      return ['P', 'DIV'].includes(node.nodeName) ? '\n\n' + text + '\n\n' : text;
    }
  });
  // GFM requires a header. For a simple headerless table, use an empty header
  // rather than misrepresenting the first data row as column names.
  doc.querySelectorAll('table').forEach(table => {
    if (table.querySelector('[rowspan], [colspan]')) throw new Error('合并单元格尚不支持，请用原格式粘贴。');
    if (table.querySelector('table')) throw new Error('嵌套表格尚不支持，请用原格式粘贴。');
    const first = table.rows[0];
    if (!first || first.parentNode.nodeName === 'THEAD' || Array.from(first.cells).every(cell => cell.tagName === 'TH')) return;
    const header = doc.createElement('thead');
    const row = doc.createElement('tr');
    for (let i = 0; i < first.cells.length; i++) row.appendChild(doc.createElement('th'));
    header.appendChild(row); table.insertBefore(header, table.firstChild);
  });
  return service.turndown(doc.body);
}
