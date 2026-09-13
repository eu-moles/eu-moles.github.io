(() => {
  const form = document.querySelector('#mep-filters');
  if (!form) return;

  const rows = Array.from(document.querySelectorAll('[data-mep-row]'));
  const rowsContainer = document.querySelector('#mep-directory-rows');
  const controls = {
    country: document.querySelector('#mep-country'),
    letter: document.querySelector('#mep-letter'),
    group: document.querySelector('#mep-group'),
    party: document.querySelector('#mep-party'),
    pageSize: document.querySelector('#mep-page-size'),
    detectionSort: document.querySelector('#mep-detection-sort'),
  };
  const summary = document.querySelector('#mep-results-summary');
  const pagination = document.querySelector('#mep-pagination');
  const paginationBottom = document.querySelector('#mep-pagination-bottom');
  const clear = document.querySelector('#mep-clear-filters');
  const pageSizeOptions = [25, 50, 100];
  let page = 1;

  const firstLetter = (row) => row.dataset.fullName.trim().charAt(0).toLocaleUpperCase();
  const query = new URLSearchParams(window.location.search);

  [...new Set(rows.map(firstLetter))]
    .sort((a, b) => a.localeCompare(b))
    .forEach((letter) => controls.letter.add(new Option(letter, letter)));

  ['country', 'letter', 'group', 'party'].forEach((name) => {
    const value = query.get(name);
    if (value && Array.from(controls[name].options).some((option) => option.value === value)) {
      controls[name].value = value;
    }
  });
  const requestedPageSize = Number(query.get('pageSize'));
  if (pageSizeOptions.includes(requestedPageSize)) controls.pageSize.value = requestedPageSize;
  controls.detectionSort.checked = query.get('detectionSort') !== '0';
  page = Math.max(1, Number(query.get('page')) || 1);

  const updateUrl = () => {
    const params = new URLSearchParams();
    ['country', 'letter', 'group', 'party'].forEach((name) => {
      if (controls[name].value) params.set(name, controls[name].value);
    });
    if (!controls.detectionSort.checked) params.set('detectionSort', '0');
    if (Number(controls.pageSize.value) !== 25) params.set('pageSize', controls.pageSize.value);
    if (page > 1) params.set('page', page);
    const suffix = params.toString();
    window.history.replaceState(null, '', `${window.location.pathname}${suffix ? `?${suffix}` : ''}`);
  };

  const makePageButton = (label, target, container, current = false) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.className = 'pv1 ph2 mr1 mb1 ba b--dark-blue bg-white dark-blue pointer';
    button.disabled = current;
    if (current) button.setAttribute('aria-current', 'page');
    button.addEventListener('click', () => {
      page = target;
      render();
      container.scrollIntoView({ block: 'nearest' });
    });
    return button;
  };

  const renderPagination = (container, pages) => {
    container.replaceChildren();
    if (pages <= 1) return;

    container.append(makePageButton('Previous', Math.max(1, page - 1), container, page === 1));
    const candidates = new Set([1, pages, page - 1, page, page + 1]);
    let previous = 0;
    [...candidates]
      .filter((value) => value >= 1 && value <= pages)
      .sort((a, b) => a - b)
      .forEach((value) => {
        if (previous && value > previous + 1) {
          const gap = document.createElement('span');
          gap.className = 'mh1';
          gap.textContent = '…';
          container.append(gap);
        }
        container.append(makePageButton(String(value), value, container, value === page));
        previous = value;
      });
    container.append(makePageButton('Next', Math.min(pages, page + 1), container, page === pages));
  };

  const render = () => {
    const pageSize = Number(controls.pageSize.value);
    const matchingRows = rows.filter((row) => (
      (!controls.country.value || row.dataset.country === controls.country.value) &&
      (!controls.letter.value || firstLetter(row) === controls.letter.value) &&
      (!controls.group.value || row.dataset.group === controls.group.value) &&
      (!controls.party.value || row.dataset.party === controls.party.value)
    ));
    const orderedRows = matchingRows.sort((left, right) => {
      if (controls.detectionSort.checked) {
        const countDifference = Number(right.dataset.detectionCount) - Number(left.dataset.detectionCount);
        if (countDifference) return countDifference;
      }
      return left.dataset.fullName.localeCompare(right.dataset.fullName);
    });
    const pages = Math.max(1, Math.ceil(orderedRows.length / pageSize));
    page = Math.min(page, pages);
    const start = (page - 1) * pageSize;
    const end = start + pageSize;

    rows.forEach((row) => { row.hidden = true; });
    orderedRows.forEach((row, index) => {
      rowsContainer.append(row);
      row.hidden = index < start || index >= end;
    });

    if (orderedRows.length) {
      const ordering = controls.detectionSort.checked ? ' — highest detections first' : '';
      summary.textContent = `${orderedRows.length} MEP record${orderedRows.length === 1 ? '' : 's'}${ordering} — showing ${start + 1}–${Math.min(end, orderedRows.length)}`;
    } else {
      summary.textContent = 'No MEP records match these filters.';
    }
    renderPagination(pagination, pages);
    renderPagination(paginationBottom, pages);
    updateUrl();
  };

  form.addEventListener('change', () => {
    page = 1;
    render();
  });
  clear.addEventListener('click', () => {
    form.reset();
    page = 1;
    render();
  });
  render();
})();
