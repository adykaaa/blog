(() => {
  const copyText = async (text) => {
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return;
      } catch {
        // Try the selection-based fallback if clipboard permission is denied.
      }
    }

    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.readOnly = true;
    textarea.className = 'code-copy-fallback';
    document.body.append(textarea);
    try {
      textarea.select();
      if (!document.execCommand('copy')) throw new Error('Copy failed');
    } finally {
      textarea.remove();
    }
  };

  const languages = ['bash', 'python', 'yaml', 'json'];
  const selector = languages.map((language) => `.post-content pre > code.language-${language}`).join(', ');
  document.querySelectorAll(selector).forEach((code) => {
    const pre = code.parentElement;
    const block = pre.closest('.highlight') || pre;
    if (block.closest('.code-example')) return;

    const wrapper = document.createElement('div');
    wrapper.className = 'code-example';
    const toolbar = document.createElement('div');
    toolbar.className = 'code-toolbar';
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'code-copy-button';
    button.textContent = 'Copy';
    button.setAttribute('aria-label', 'Copy code to clipboard');
    button.setAttribute('aria-live', 'polite');

    let resetTimer;
    button.addEventListener('click', async () => {
      clearTimeout(resetTimer);
      button.disabled = true;
      try {
        await copyText(code.textContent);
        button.textContent = 'Copied!';
        button.setAttribute('aria-label', 'Code copied to clipboard');
      } catch {
        button.textContent = 'Copy failed';
        button.setAttribute('aria-label', 'Copy failed. Select the code and copy it manually.');
      } finally {
        button.disabled = false;
        button.focus({ preventScroll: true });
        resetTimer = setTimeout(() => {
          button.textContent = 'Copy';
          button.setAttribute('aria-label', 'Copy code to clipboard');
        }, 2500);
      }
    });

    block.before(wrapper);
    toolbar.append(button);
    wrapper.append(toolbar, block);
  });
})();
