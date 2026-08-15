(() => {
  const profile = document.querySelector('#mep-profile');
  if (!profile) return;

  const status = document.querySelector('#mep-profile-status');
  const error = document.querySelector('#mep-profile-error');
  const back = document.querySelector('#mep-profile-back');
  const id = new URLSearchParams(window.location.search).get('id');

  const showError = (message) => {
    profile.hidden = true;
    profile.setAttribute('aria-busy', 'false');
    status.hidden = true;
    error.textContent = message;
    error.hidden = false;
  };

  back.addEventListener('click', () => {
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
    })
    .catch(() => showError('The MEP directory could not be loaded. Please try again later.'));
})();
