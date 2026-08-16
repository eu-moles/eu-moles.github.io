(() => {
  const profile = document.querySelector('#mep-profile');
  if (!profile) return;

  const status = document.querySelector('#mep-profile-status');
  const error = document.querySelector('#mep-profile-error');
  const back = document.querySelector('#mep-profile-back');
  const motions = document.querySelector('#mep-profile-motions');
  const parameters = new URLSearchParams(window.location.search);
  const id = parameters.get('id');
  const returnTarget = parameters.get('return');

  const internalReturnURL = () => {
    if (!returnTarget) return null;
    try {
      const target = new URL(returnTarget, window.location.origin);
      return target.origin === window.location.origin ? target.href : null;
    } catch (_) {
      return null;
    }
  };

  const showError = (message) => {
    profile.hidden = true;
    profile.setAttribute('aria-busy', 'false');
    status.hidden = true;
    error.textContent = message;
    error.hidden = false;
  };

  const make = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text) element.textContent = text;
    return element;
  };

  const appendMotionTitle = (container, text) => {
    if (window.EUMolesMotionContext && typeof window.EUMolesMotionContext.highlightText === 'function') {
      window.EUMolesMotionContext.highlightText(container, text);
      return;
    }
    container.textContent = text;
  };

  const voteBadge = (position) => {
    const labels = {
      for: ['In favour', 'fa-thumbs-up'],
      against: ['Against', 'fa-thumbs-down'],
      abstention: ['Abstained', 'fa-minus'],
      notRecorded: ['No recorded vote', 'fa-circle-minus'],
    };
    const [label, icon] = labels[position] || labels.notRecorded;
    const badge = make('span', `mep-motion-vote mep-motion-vote--${position}`);
    const marker = make('i', `fa-solid ${icon}`);
    marker.setAttribute('aria-hidden', 'true');
    badge.append(marker, document.createTextNode(label));
    return badge;
  };

  const outcomeBadge = (result) => {
    const normalised = String(result || '').toLowerCase();
    const badge = make('span', `motion-result motion-result--${normalised}`);
    const icons = { adopted: 'fa-thumbs-up', rejected: 'fa-thumbs-down' };
    if (icons[normalised]) {
      const marker = make('i', `fa-solid ${icons[normalised]}`);
      marker.setAttribute('aria-hidden', 'true');
      badge.append(marker);
    }
    badge.append(document.createTextNode(result ? `${result.charAt(0)}${result.slice(1).toLowerCase()}` : 'Not listed'));
    return badge;
  };

  const renderMotions = (mepID) => {
    if (!motions) return;
    const rows = document.querySelector('#mep-profile-motion-rows');
    const summary = document.querySelector('#mep-profile-motions-summary');
    const empty = document.querySelector('#mep-profile-motions-empty');

    fetch(motions.dataset.motionsUrl, { credentials: 'same-origin' })
      .then((response) => {
        if (!response.ok) throw new Error('Voting data could not be loaded.');
        return response.json();
      })
      .then((items) => {
        if (!items.length) {
          empty.textContent = 'No recorded roll-call votes are available yet.';
          empty.hidden = false;
          motions.hidden = false;
          return;
        }

        summary.textContent = `${items.length} recorded ${items.length === 1 ? 'motion' : 'motions'}`;
        items.forEach((motion) => {
          const row = document.createElement('tr');
          const date = make('td', 'mep-profile-motion-date', String(motion.date).slice(0, 10));
          const motionCell = make('td', 'mep-profile-motion-title');
          const title = make('span', 'mep-profile-motion-title-text');
          appendMotionTitle(title, motion.title);
          motionCell.append(title);

          if (Array.isArray(motion.discussion) && motion.discussion.length && window.EUMolesMotionContext) {
            const context = make('button', 'motion-context-link');
            context.type = 'button';
            context.setAttribute('aria-haspopup', 'dialog');
            const marker = make('i', 'fa-solid fa-book-open');
            marker.setAttribute('aria-hidden', 'true');
            context.append(marker, document.createTextNode('Discussion'));
            context.addEventListener('click', () => {
              window.EUMolesMotionContext.open(motion, context, motions.dataset.profileUrl);
            });
            motionCell.append(context);
          }

          if (motion.sourceTitle && motion.sourceTitle !== motion.title) {
            const source = make('span', 'mep-profile-motion-source');
            source.append(document.createTextNode('Source: '));
            const sourceLink = make('a', 'motion-source-link', motion.sourceTitle);
            sourceLink.href = motion.sourceURL;
            sourceLink.target = '_blank';
            sourceLink.rel = 'external noopener noreferrer';
            source.append(sourceLink);
            motionCell.append(source);
          }

          const position = motion.positions && motion.positions[mepID] ? motion.positions[mepID] : 'notRecorded';
          const vote = document.createElement('td');
          vote.append(voteBadge(position));
          const outcome = document.createElement('td');
          outcome.append(outcomeBadge(motion.result));
          row.append(date, motionCell, vote, outcome);
          rows.append(row);
        });
        motions.hidden = false;

        const requestedContext = new URLSearchParams(window.location.search).get('context');
        const requestedMotion = items.find((motion) => motion.contextID === requestedContext);
        if (requestedMotion && window.EUMolesMotionContext) {
          window.EUMolesMotionContext.open(requestedMotion, null, motions.dataset.profileUrl, false);
        }
      })
      .catch(() => {
        empty.textContent = 'Voting data could not be loaded.';
        empty.hidden = false;
        motions.hidden = false;
      });
  };

  back.addEventListener('click', () => {
    const returnURL = internalReturnURL();
    if (returnURL) {
      window.location.assign(returnURL);
      return;
    }

    try {
      const previous = document.referrer ? new URL(document.referrer) : null;
      if (previous && previous.origin === window.location.origin) {
        window.history.back();
        return;
      }
    } catch (_) {
      // Use the directory fallback below when the referrer cannot be parsed.
    }
    window.location.assign(back.dataset.fallback);
  });

  if (!/^\d+$/.test(id || '')) {
    showError('No valid MEP ID was provided.');
    return;
  }

  fetch(profile.dataset.directoryUrl, { credentials: 'same-origin' })
    .then((response) => {
      if (!response.ok) throw new Error('Directory data could not be loaded.');
      return response.json();
    })
    .then((meps) => {
      const mep = meps.find((item) => String(item.id) === id);
      if (!mep) {
        showError('No MEP profile was found for this ID.');
        return;
      }

      const photo = document.querySelector('#mep-profile-photo');
      photo.src = `https://www.europarl.europa.eu/mepphoto/${encodeURIComponent(mep.id)}.jpg`;
      photo.alt = `Portrait of ${mep.fullName}`;
      document.querySelector('#mep-profile-country').textContent = `${mep.countryFlag} ${mep.country}`;
      document.querySelector('#mep-profile-member-state').textContent = `${mep.countryFlag} ${mep.country}`;
      document.querySelector('#mep-profile-name').textContent = mep.fullName;
      document.querySelector('#mep-profile-group').textContent = mep.politicalGroup || 'Not listed';
      document.querySelector('#mep-profile-party').textContent = mep.nationalPoliticalGroup || 'Not listed';
      document.querySelector('#mep-profile-id').textContent = mep.id;

      const official = document.querySelector('#mep-profile-official');
      official.href = `https://www.europarl.europa.eu/meps/en/${encodeURIComponent(mep.id)}`;

      document.title = `${mep.fullName} | EU Moles`;
      profile.hidden = false;
      profile.setAttribute('aria-busy', 'false');
      status.hidden = true;
      renderMotions(mep.id);
    })
    .catch(() => showError('The MEP directory could not be loaded. Please try again later.'));
})();
