(() => {
  const parseDate = (value) => {
    const [year, month, day] = value.split('-').map(Number);
    return new Date(Date.UTC(year, month - 1, day));
  };
  const dateKey = (date) => date.toISOString().slice(0, 10);
  const monthKey = (date) => date.getUTCFullYear() * 12 + date.getUTCMonth();
  const displayDate = new Intl.DateTimeFormat('en', {
    day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC',
  });
  const displayMonth = new Intl.DateTimeFormat('en', {
    month: 'long', year: 'numeric', timeZone: 'UTC',
  });

  const bind = (calendar, options = {}) => {
    if (!calendar || calendar.dataset.motionCalendarBound === 'true') return;

    const rows = options.rows ? [...options.rows] : [...document.querySelectorAll('[data-motion-date]')];
    const parentRows = rows.filter((row) => row.dataset.motionVotingId);
    const suppliedDates = options.dates || (calendar.dataset.availableDates || '').split(',').filter(Boolean);
    const dates = [...new Set(suppliedDates.length ? suppliedDates : parentRows.map((row) => row.dataset.motionDate))].sort();
    if (!dates.length) return;

    calendar.dataset.motionCalendarBound = 'true';
    const available = new Set(dates);
    const dateCounts = dates.reduce((counts, date) => {
      counts[date] = parentRows.filter((row) => row.dataset.motionDate === date).length;
      return counts;
    }, {});
    const params = new URLSearchParams(window.location.search);
    const contextID = params.get('context') || '';
    const contextRow = options.contextRow || (contextID
      ? rows.find((row) => row.dataset.motionContextId === contextID)
      : null);
    let selected = available.has(params.get('date'))
      ? params.get('date')
      : (contextRow?.dataset.motionDate || options.defaultDate || calendar.dataset.defaultDate || dates.at(-1));
    let displayedMonth = parseDate(selected);
    displayedMonth.setUTCDate(1);

    const days = calendar.querySelector('[data-motion-calendar-days]');
    const month = calendar.querySelector('[data-motion-calendar-month]');
    const previous = calendar.querySelector('[data-motion-calendar-previous]');
    const next = calendar.querySelector('[data-motion-calendar-next]');
    const count = options.countElement || document.querySelector('[data-motion-calendar-count]');
    const firstMonth = monthKey(parseDate(dates[0]));
    const lastMonth = monthKey(parseDate(dates.at(-1)));

    const updateRows = () => {
      rows.forEach((row) => {
        row.dataset.calendarHidden = String(row.dataset.motionDate !== selected);
        row.hidden = row.dataset.calendarHidden === 'true';
      });
      window.EUMolesSubvotes?.refresh?.();
      const number = dateCounts[selected] || 0;
      if (count) {
        count.textContent = `${number} recorded ${number === 1 ? 'motion' : 'motions'} — ${displayDate.format(parseDate(selected))}`;
      }
      if (options.updateURL !== false) {
        const url = new URL(window.location.href);
        url.searchParams.set('date', selected);
        history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
      }
    };

    const selectDate = (date) => {
      selected = date;
      displayedMonth = parseDate(date);
      displayedMonth.setUTCDate(1);
      updateRows();
      render();
    };

    const render = () => {
      month.textContent = displayMonth.format(displayedMonth);
      previous.disabled = monthKey(displayedMonth) <= firstMonth;
      next.disabled = monthKey(displayedMonth) >= lastMonth;
      days.replaceChildren();

      const firstWeekday = (displayedMonth.getUTCDay() + 6) % 7;
      for (let blank = 0; blank < firstWeekday; blank += 1) {
        const spacer = document.createElement('span');
        spacer.className = 'motion-calendar__day motion-calendar__day--empty';
        spacer.setAttribute('aria-hidden', 'true');
        days.append(spacer);
      }

      const year = displayedMonth.getUTCFullYear();
      const monthIndex = displayedMonth.getUTCMonth();
      const daysInMonth = new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate();
      for (let day = 1; day <= daysInMonth; day += 1) {
        const date = dateKey(new Date(Date.UTC(year, monthIndex, day)));
        const button = document.createElement('button');
        const isAvailable = available.has(date);
        button.className = `motion-calendar__day${isAvailable ? ' motion-calendar__day--available' : ''}${date === selected ? ' is-selected' : ''}`;
        button.type = 'button';
        button.textContent = String(day);
        button.disabled = !isAvailable;
        button.setAttribute('role', 'gridcell');
        button.setAttribute('aria-selected', String(date === selected));
        button.title = isAvailable
          ? `${displayDate.format(parseDate(date))}: ${dateCounts[date]} recorded ${dateCounts[date] === 1 ? 'motion' : 'motions'}`
          : displayDate.format(parseDate(date));
        if (isAvailable) button.addEventListener('click', () => selectDate(date));
        days.append(button);
      }
    };

    previous.addEventListener('click', () => {
      displayedMonth.setUTCMonth(displayedMonth.getUTCMonth() - 1);
      render();
    });
    next.addEventListener('click', () => {
      displayedMonth.setUTCMonth(displayedMonth.getUTCMonth() + 1);
      render();
    });

    calendar.hidden = false;
    updateRows();
    render();
  };

  window.EUMolesMotionCalendar = { bind };
  document.querySelectorAll('[data-motion-calendar][data-available-dates]').forEach((calendar) => bind(calendar));
})();
