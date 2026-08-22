(() => {
  const childrenFor = (group) => [...document.querySelectorAll('[data-subvotes-child]')]
    .filter((row) => row.dataset.subvotesChild === group);

  const setExpanded = (button, expanded) => {
    const group = button.dataset.subvotesToggle;
    childrenFor(group).forEach((row) => {
      row.hidden = !expanded || row.dataset.calendarHidden === 'true';
    });
    button.setAttribute('aria-expanded', String(expanded));
    const count = button.dataset.subvotesCount || '0';
    const noun = count === '1' ? 'component vote' : 'component votes';
    button.title = `${expanded ? 'Hide' : 'Show'} vote breakdown`;
    button.setAttribute('aria-label', `${expanded ? 'Hide' : 'Show'} vote breakdown: ${count} ${noun}`);

    const icon = button.querySelector('i');
    if (icon) icon.className = `fa-solid fa-${expanded ? 'minus' : 'plus'}`;

  };

  const bind = (root = document) => {
    root.querySelectorAll('[data-subvotes-toggle]').forEach((button) => {
      if (button.dataset.subvotesBound === 'true') return;
      button.dataset.subvotesBound = 'true';
      button.addEventListener('click', () => setExpanded(button, button.getAttribute('aria-expanded') !== 'true'));
    });
  };

  const refresh = (root = document) => {
    root.querySelectorAll('[data-subvotes-toggle]').forEach((button) => {
      setExpanded(button, button.getAttribute('aria-expanded') === 'true');
    });
  };

  window.EUMolesSubvotes = { bind, refresh };
  bind();
})();
