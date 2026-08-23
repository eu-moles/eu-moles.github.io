(() => {
  const profile = document.querySelector('#mep-profile');
  if (!profile) return;

  const status = document.querySelector('#mep-profile-status');
  const error = document.querySelector('#mep-profile-error');
  const back = document.querySelector('#mep-profile-back');
  const motions = document.querySelector('#mep-profile-motions');
  const motionCalendar = motions?.querySelector('[data-motion-calendar]');
  const speeches = document.querySelector('#mep-profile-speeches');
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

  const setCountryIdentity = (element, flag, country) => {
    const identity = make('span', 'country-identity', `${flag} ${country}`);
    element.replaceChildren(identity);
  };

  const appendMotionTitle = (container, text) => {
    if (window.EUMolesMotionContext && typeof window.EUMolesMotionContext.highlightText === 'function') {
      window.EUMolesMotionContext.highlightText(container, text);
      return;
    }
    container.textContent = text;
  };

  const documentLink = (label, url, icon, title) => {
    const link = make('a');
    link.href = url;
    link.target = '_blank';
    link.rel = 'external noopener noreferrer';
    link.title = title;
    const marker = make('i', `fa-solid ${icon}`);
    marker.setAttribute('aria-hidden', 'true');
    link.append(marker, document.createTextNode(label));
    return link;
  };

  const motionDocuments = (motion) => {
    const documents = make('div', 'motion-documents');
    if (motion.procedureURL) {
      documents.append(documentLink('Procedure', motion.procedureURL, 'fa-diagram-project', `Open procedure ${motion.procedureReference || ''}`.trim()));
    }
    if (Array.isArray(motion.procedureDocuments)) {
      motion.procedureDocuments.forEach((document) => {
        if (!document || !document.url || !document.id) return;
        const icon = document.url.endsWith('.pdf') ? 'fa-file-pdf' : 'fa-file-lines';
        const label = document.title || document.id;
        documents.append(documentLink(label, document.url, icon, `Open ${label} (${document.id})`));
      });
    }
    if (motion.contextURL) {
      documents.append(documentLink('Transcript', motion.contextURL, 'fa-comments', 'Open official debate transcript'));
    }
    return documents;
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

  const containsTrackedKeyword = (text) => {
    if (window.EUMolesMotionContext && typeof window.EUMolesMotionContext.containsTrackedKeyword === 'function') {
      return window.EUMolesMotionContext.containsTrackedKeyword(text);
    }
    return /\b(russ\p{L}*(?:['’]s)?|ukrain\p{L}*(?:['’]s)?|nato\b(?:['’]s)?|belarus\p{L}*(?:['’]s)?)/iu.test(String(text || ''));
  };

  const renderSpeechText = (container, text) => {
    if (window.EUMolesMotionContext && typeof window.EUMolesMotionContext.renderBubbleText === 'function') {
      window.EUMolesMotionContext.renderBubbleText(container, text, true);
      return;
    }
    container.textContent = text;
  };

  const appendSpeech = (container, speech) => {
    const article = make('article', 'mep-profile-speech');
    const avatar = make('div', 'mep-profile-speech-avatar');
    const image = document.createElement('img');
    image.src = `https://www.europarl.europa.eu/mepphoto/${encodeURIComponent(speech.mepID)}.jpg`;
    image.alt = `Portrait of ${speech.speaker || 'the Member'}`;
    image.loading = 'lazy';
    avatar.append(image);

    const content = make('div', 'mep-profile-speech-content');
    const meta = make('header', 'mep-profile-speech-meta');
    const date = make('time', 'mep-profile-speech-date', String(speech.date || '').slice(0, 10));
    date.dateTime = String(speech.date || '').slice(0, 10);
    const topic = speech.sourceURL
      ? make('a', 'mep-profile-speech-topic')
      : make('span', 'mep-profile-speech-topic');
    if (speech.sourceURL) {
      topic.href = speech.sourceURL;
      topic.target = '_blank';
      topic.rel = 'external noopener noreferrer';
    }
    topic.append(document.createTextNode(speech.topic || 'One-minute speech'));
    if (speech.sourceURL) {
      const icon = make('i', 'fa-solid fa-arrow-up-right-from-square');
      icon.setAttribute('aria-hidden', 'true');
      topic.append(document.createTextNode(' '), icon);
    }
    meta.append(date, topic);

    const bubble = make('div', 'motion-context-bubble');
    const text = make('div', 'motion-context-bubble__text');
    text.setAttribute('aria-live', 'polite');
    const translation = String(speech.translation?.englishText || '');
    renderSpeechText(text, translation || String(speech.text || ''));
    bubble.append(text);
    if (speech.language && speech.language.code && window.EUMolesMotionContext
      && typeof window.EUMolesMotionContext.createTranslationButton === 'function') {
      bubble.append(window.EUMolesMotionContext.createTranslationButton(speech.language, speech.text, speech.translation));
    }
    content.append(bubble, meta);
    article.append(avatar, content);
    container.append(article);
  };

  const renderSpeeches = (mepID) => {
    if (!speeches) return;
    const list = document.querySelector('#mep-profile-speech-list');
    const summary = document.querySelector('#mep-profile-speeches-summary');
    const empty = document.querySelector('#mep-profile-speeches-empty');

    fetch(speeches.dataset.speechesUrl, { credentials: 'same-origin' })
      .then((response) => {
        if (!response.ok) throw new Error('Speech data could not be loaded.');
        return response.json();
      })
      .then((items) => {
        const relevant = items.filter((speech) => {
          if (String(speech.mepID) !== String(mepID)) return false;
          const translation = String(speech.translation?.englishText || '');
          const searchableText = translation || (speech.language && speech.language.code ? '' : String(speech.text || ''));
          return Boolean(searchableText) && containsTrackedKeyword(searchableText);
        });

        if (!relevant.length) {
          empty.textContent = 'No speeches containing tracked terms are available for this Member.';
          empty.hidden = false;
          speeches.hidden = false;
          return;
        }

        summary.textContent = `${relevant.length} tracked ${relevant.length === 1 ? 'speech' : 'speeches'}`;
        relevant.forEach((speech) => appendSpeech(list, speech));
        speeches.hidden = false;
      })
      .catch(() => {
        empty.textContent = 'Speech data could not be loaded.';
        empty.hidden = false;
        speeches.hidden = false;
      });
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
        const voterIDs = (voters) => Array.isArray(voters) ? voters : [];
        const positionFor = (motion) => (voterIDs(motion.votersFor).includes(mepID)
          ? 'for'
          : voterIDs(motion.votersAgainst).includes(mepID)
            ? 'against'
            : voterIDs(motion.votersAbstaining).includes(mepID)
              ? 'abstention'
              : 'notRecorded');
        // A profile is also a complete view of the sitting record. Keep motions
        // where the Member has no recorded vote, and make that absence explicit.
        const relevant = items;

        if (!relevant.length) {
          empty.textContent = 'No recorded motions are available yet.';
          empty.hidden = false;
          motions.hidden = false;
          return;
        }

        const parentCount = relevant.filter((motion) => !motion.isSubvote).length;
        summary.textContent = `${parentCount} recorded ${parentCount === 1 ? 'motion' : 'motions'}`;
        relevant.forEach((motion) => {
          const row = document.createElement('tr');
          row.dataset.motionDate = String(motion.date || '').slice(0, 10);
          if (!motion.isSubvote) {
            row.dataset.motionVotingId = motion.contextID || motion.parentID;
            row.dataset.motionContextId = motion.contextID || '';
          }
          if (motion.isSubvote) row.classList.add('motion-subvote-row');
          if (motion.hasSubvotes) row.classList.add('motion-parent-row');
          if (motion.isSubvote) {
            row.dataset.subvotesChild = motion.parentID;
          } else if (motion.hasSubvotes) {
            row.dataset.subvotesParent = motion.parentID;
          }
          const date = make('td', 'site-table-date', String(motion.date).slice(0, 10));
          date.dataset.label = 'Date';
          const type = make('td', 'motion-type-cell');
          type.dataset.label = 'Classification';
          const typeBadges = make('span', 'motion-type-badges');
          if (!motion.isSubvote && motion.agendaRequest) {
            const agenda = make('span', 'motion-agenda-badge');
            agenda.title = 'Agenda request';
            const icon = make('i', 'fa-solid fa-calendar-plus');
            icon.setAttribute('aria-hidden', 'true');
            agenda.append(icon, document.createTextNode('Agenda request'));
            typeBadges.append(agenda);
          }
          if (!motion.isSubvote && motion.procedure) {
            const procedureClasses = {
              'First reading': 'motion-procedure-badge--first',
              'Second reading': 'motion-procedure-badge--second',
              Conciliation: 'motion-procedure-badge--conciliation',
            };
            const procedure = make('span', `motion-procedure-badge ${procedureClasses[motion.procedure] || 'motion-procedure-badge--first'}`);
            procedure.title = 'Legislative procedure stage';
            const icon = make('i', 'fa-solid fa-landmark');
            icon.setAttribute('aria-hidden', 'true');
            procedure.append(icon, document.createTextNode(motion.procedure));
            typeBadges.append(procedure);
          }
          if (!motion.isSubvote && motion.tracked) {
            const tracked = make('span', 'motion-tracked-badge');
            tracked.title = 'Contains tracked terms';
            const icon = make('i', 'fa-solid fa-bullseye');
            icon.setAttribute('aria-hidden', 'true');
            tracked.append(icon, document.createTextNode('Tracked'));
            typeBadges.append(tracked);
          }
          if (!motion.isSubvote && typeBadges.childElementCount) {
            type.append(typeBadges);
          } else {
            type.classList.add('motion-type-cell--empty');
          }
          const disclosure = make(
            'td',
            `motion-disclosure-cell${motion.hasSubvotes ? '' : ' motion-disclosure-cell--empty'}`,
          );
          disclosure.dataset.label = '';
          if (motion.hasSubvotes) {
            const count = relevant.filter((item) => item.isSubvote && item.parentID === motion.parentID).length;
            const toggle = make('button', 'motion-subvotes-toggle');
            toggle.type = 'button';
            toggle.dataset.subvotesToggle = motion.parentID;
            toggle.dataset.subvotesCount = String(count);
            toggle.setAttribute('aria-expanded', 'true');
            toggle.setAttribute('aria-label', `Hide vote breakdown: ${count} component ${count === 1 ? 'vote' : 'votes'}`);
            toggle.title = 'Hide vote breakdown';
            const icon = make('i', 'fa-solid fa-minus');
            icon.setAttribute('aria-hidden', 'true');
            toggle.append(icon);
            disclosure.append(toggle);
          }
          const reference = make(
            'td',
            `motion-reference-cell${motion.reference ? '' : ' motion-reference-cell--empty'}`,
          );
          reference.dataset.label = 'Reference';
          reference.textContent = motion.reference || '';
          const motionCell = make('td', 'mep-profile-motion-title');
          motionCell.dataset.label = 'Motion';
          if (motion.isSubvote) {
            motionCell.classList.add('motion-subvote-title');
          }
          const title = motion.sourceURL && !motion.isSubvote
            ? make('a', 'mep-profile-motion-title-text')
            : make('span', 'mep-profile-motion-title-text');
          if (motion.sourceURL && !motion.isSubvote) {
            title.href = motion.sourceURL;
            title.target = '_blank';
            title.rel = 'external noopener noreferrer';
            title.title = 'Open official sitting record';
          }
          appendMotionTitle(title, motion.title);
          if (motion.sourceURL && !motion.isSubvote) {
            const icon = make('i', 'fa-solid fa-arrow-up-right-from-square');
            icon.setAttribute('aria-hidden', 'true');
            title.append(document.createTextNode(' '), icon);
          }
          motionCell.append(title);

          if (Array.isArray(motion.discussion) && motion.discussion.length && window.EUMolesMotionContext) {
            const context = make('button', 'motion-discussion-link');
            context.type = 'button';
            context.setAttribute('aria-haspopup', 'dialog');
            const marker = make('i', 'fa-solid fa-book-open');
            marker.setAttribute('aria-hidden', 'true');
            context.append(marker, document.createTextNode('Discussion transcript'));
            context.addEventListener('click', () => {
              window.EUMolesMotionContext.open(motion, context, motions.dataset.profileUrl);
            });
            motionCell.append(context);
          }

          const hasDocuments = !motion.isSubvote
            && Boolean(motion.procedureURL || motion.contextURL
              || (Array.isArray(motion.procedureDocuments) && motion.procedureDocuments.length));
          const documents = make('td', `motion-documents-cell${hasDocuments ? '' : ' motion-documents-cell--empty'}`);
          documents.dataset.label = 'Documents';
          if (hasDocuments) documents.append(motionDocuments(motion));

          const position = positionFor(motion);
          const vote = document.createElement('td');
          vote.dataset.label = 'Vote';
          if (motion.hasSubvotes) vote.classList.add('motion-unavailable-cell');
          if (!motion.hasSubvotes) vote.append(voteBadge(position));
          const outcome = document.createElement('td');
          outcome.dataset.label = 'Outcome';
          if (motion.hasSubvotes) outcome.classList.add('motion-unavailable-cell');
          if (!motion.hasSubvotes) outcome.append(outcomeBadge(motion.result));
          row.append(date, type, disclosure, reference, motionCell, documents, vote, outcome);
          rows.append(row);
        });
        if (window.EUMolesSubvotes) window.EUMolesSubvotes.bind(rows);
        if (window.EUMolesMotionCalendar && motionCalendar) {
          window.EUMolesMotionCalendar.bind(motionCalendar, {
            rows: rows.querySelectorAll('[data-motion-date]'),
            countElement: summary,
          });
        }
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
      setCountryIdentity(document.querySelector('#mep-profile-country'), mep.countryFlag, mep.country);
      setCountryIdentity(document.querySelector('#mep-profile-member-state'), mep.countryFlag, mep.country);
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
      renderSpeeches(mep.id);
    })
    .catch(() => showError('The MEP directory could not be loaded. Please try again later.'));
})();
