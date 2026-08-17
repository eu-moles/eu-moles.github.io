(() => {
  const childrenFor = (group) => [...document.querySelectorAll('[data-subvotes-child]')]
    .filter((row) => row.dataset.subvotesChild === group);

  const setExpanded = (button, expanded) => {
    const group = button.dataset.subvotesToggle;
    childrenFor(group).forEach((row) => { row.hidden = !expanded; });
    button.setAttribute('aria-expanded', String(expanded));
    const count = button.dataset.subvotesCount || '0';
    const noun = count === '1' ? 'component vote' : 'component votes';
    button.title = `${expanded ? 'Hide' : 'Show'} ${noun}`;
    button.setAttribute('aria-label', `${expanded ? 'Hide' : 'Show'} ${count} ${noun}`);

    const icon = button.querySelector('i');
    if (icon) icon.className = `fa-solid fa-${expanded ? 'minus' : 'plus'}`;

  };

  document.querySelectorAll('[data-subvotes-toggle]').forEach((button) => {
    button.addEventListener('click', () => setExpanded(button, button.getAttribute('aria-expanded') !== 'true'));
  });
})();
