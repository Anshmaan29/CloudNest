// These functions must remain self-contained: Chrome serializes only the function.
// They run once, in the isolated world, after the matching popup button is clicked.
export function selectedText() {
  const active = document.activeElement;
  if (active?.tagName === 'INPUT' && active.type === 'password') return { error: 'Password fields cannot be captured.' };
  let text = window.getSelection()?.toString() || '';
  if (active?.tagName === 'TEXTAREA' || (active?.tagName === 'INPUT' && ['text', 'search'].includes(active.type))) text = active.value.slice(active.selectionStart ?? 0, active.selectionEnd ?? 0);
  if (!text.trim()) return { error: 'Select the exact text to propose first. No page content was collected.' };
  if (text.length > 10000) return { error: 'Select at most 10,000 characters.' };
  return { text, source: location.origin + ' · user-selected text' };
}
export function insertText(text) {
  if (typeof text !== 'string' || !text || text.length > 20000) return { error: 'Context is empty or exceeds the insertion limit.' };
  const active = document.activeElement;
  if (!active || active.disabled || active.readOnly) return { error: 'Focus a writable message field first, or copy the context manually.' };
  if (active.tagName === 'TEXTAREA') {
    const start = active.selectionStart, end = active.selectionEnd;
    if (active.maxLength >= 0 && active.value.length - (end - start) + text.length > active.maxLength) return { error: 'Context exceeds this field’s limit. Use manual copy.' };
    active.setRangeText(text, start, end, 'end');
    active.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    return { inserted: true };
  }
  if (active.isContentEditable && active.getAttribute('role') !== 'searchbox') {
    const selection = window.getSelection();
    if (!selection?.rangeCount || !active.contains(selection.getRangeAt(0).commonAncestorContainer)) return { error: 'No insertion caret inside the focused editor. Use manual copy.' };
    if (document.execCommand('insertText', false, text)) return { inserted: true };
  }
  return { error: 'This editor does not support safe insertion. Copy and paste manually.' };
}
