(() => {
  "use strict";

  const contextParameter = "context";

  const updateContext = (id) => {
    const url = new URL(window.location.href);
    if (id) url.searchParams.set(contextParameter, id);
    else url.searchParams.delete(contextParameter);
    window.history.replaceState(null, "", url);
  };

  const make = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text) element.textContent = text;
    return element;
  };

  const appendProcedureText = (container, text) => {
    const expression = /(\d{4}\/\d{4}\([A-Z]{2,10}\))/g;
    let lastIndex = 0;
    let match;
    while ((match = expression.exec(text)) !== null) {
      container.append(document.createTextNode(text.slice(lastIndex, match.index)));
      const link = make("a", "motion-transcript-reference", match[1]);
      link.href = `https://oeil.europarl.europa.eu/oeil/en/procedure-file?reference=${encodeURIComponent(match[1])}`;
      link.target = "_blank";
      link.rel = "external noopener noreferrer";
      const icon = make("i", "fa-solid fa-arrow-up-right-from-square");
      icon.setAttribute("aria-hidden", "true");
      link.append(document.createTextNode(" "), icon);
      container.append(link);
      lastIndex = expression.lastIndex;
    }
    container.append(document.createTextNode(text.slice(lastIndex)));
  };

  const returnURLFor = (contextID) => {
    const url = new URL(window.location.href);
    url.searchParams.set(contextParameter, contextID);
    return `${url.pathname}${url.search}`;
  };

  const profileLink = (profileURL, mepID, speaker, contextID) => {
    const link = make("a");
    link.href = `${profileURL}?id=${encodeURIComponent(mepID)}&return=${encodeURIComponent(returnURLFor(contextID))}`;
    link.setAttribute("aria-label", `View profile for ${speaker}`);
    return link;
  };

  const bindDialog = (dialog) => {
    if (dialog.dataset.motionContextBound) return;
    dialog.dataset.motionContextBound = "true";

    dialog.querySelectorAll("[data-motion-context-close]").forEach((closer) => {
      closer.addEventListener("click", () => dialog.close());
    });

    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) dialog.close();
    });

    dialog.addEventListener("close", () => {
      const activeContext = new URLSearchParams(window.location.search).get(contextParameter);
      if (activeContext === dialog.id) updateContext("");
      if (dialog._motionContextOpener) dialog._motionContextOpener.focus();
    });
  };

  const showDialog = (dialog, opener, writeURL = true) => {
    bindDialog(dialog);
    dialog._motionContextOpener = opener || null;
    if (writeURL) updateContext(dialog.id);
    if (!dialog.open) dialog.showModal();
  };

  const createDiscussionDialog = (motion, profileURL) => {
    const dialog = make("dialog", "motion-context-modal");
    dialog.id = motion.contextID;
    dialog.setAttribute("aria-labelledby", `${motion.contextID}-title`);

    const shell = make("div", "motion-context-modal__shell");
    const header = make("header", "motion-context-modal__header");
    const heading = document.createElement("div");
    heading.append(make("p", "motion-context-modal__eyebrow", "Discussion transcript"));
    const title = make("h2", "", motion.title);
    title.id = `${motion.contextID}-title`;
    heading.append(title);
    const close = make("button", "motion-context-modal__close");
    close.type = "button";
    close.dataset.motionContextClose = "";
    close.setAttribute("aria-label", "Close discussion");
    const closeIcon = make("i", "fa-solid fa-xmark");
    closeIcon.setAttribute("aria-hidden", "true");
    close.append(closeIcon);
    header.append(heading, close);

    const note = make("div", "motion-context-modal__note");
    const languageIcon = make("i", "fa-solid fa-language");
    languageIcon.setAttribute("aria-hidden", "true");
    note.append(languageIcon, document.createTextNode("Remarks are reproduced in the original language recorded by Parliament."));

    const transcript = make("div", "motion-context-transcript");
    motion.discussion.forEach((turn) => {
      const turnElement = make("article", `motion-context-turn${turn.speaker === "President" ? " motion-context-turn--chair" : ""}`);
      let avatar;
      if (turn.mepID) {
        avatar = profileLink(profileURL, turn.mepID, turn.speaker, motion.contextID);
        avatar.className = "motion-context-avatar";
        const image = document.createElement("img");
        image.src = `https://www.europarl.europa.eu/mepphoto/${encodeURIComponent(turn.mepID)}.jpg`;
        image.alt = `Portrait of ${turn.speaker}`;
        image.loading = "lazy";
        avatar.append(image);
      } else {
        avatar = make("div", "motion-context-avatar");
        avatar.setAttribute("aria-hidden", "true");
        const landmark = make("i", "fa-solid fa-landmark");
        avatar.append(landmark);
      }

      const content = make("div", "motion-context-turn__content");
      const speaker = make("p", "motion-context-turn__speaker");
      if (turn.mepID) {
        const speakerLink = profileLink(profileURL, turn.mepID, turn.speaker, motion.contextID);
        speakerLink.textContent = turn.speaker;
        speaker.append(speakerLink);
      } else {
        speaker.textContent = turn.speaker;
      }
      const bubble = make("div", "motion-context-bubble");
      String(turn.text || "").split(/\n{2,}/).forEach((paragraph, index) => {
        if (index) bubble.append(document.createElement("br"), document.createElement("br"));
        appendProcedureText(bubble, paragraph);
      });
      content.append(speaker, bubble);
      turnElement.append(avatar, content);
      transcript.append(turnElement);
    });

    shell.append(header, note, transcript);
    if (motion.contextURL) {
      const footer = make("footer", "motion-context-modal__footer");
      const source = make("a", "", "Open the official sitting record ");
      source.href = motion.contextURL;
      source.target = "_blank";
      source.rel = "external noopener noreferrer";
      const sourceIcon = make("i", "fa-solid fa-arrow-up-right-from-square");
      sourceIcon.setAttribute("aria-hidden", "true");
      source.append(sourceIcon);
      footer.append(source);
      shell.append(footer);
    }
    dialog.append(shell);
    document.body.append(dialog);
    return dialog;
  };

  window.EUMolesMotionContext = {
    open(motion, opener, profileURL, writeURL = true) {
      if (!motion || !motion.contextID || !Array.isArray(motion.discussion) || !motion.discussion.length) return;
      const dialog = document.getElementById(motion.contextID) || createDiscussionDialog(motion, profileURL);
      showDialog(dialog, opener, writeURL);
    },
  };

  document.querySelectorAll("[data-motion-context-open]").forEach((opener) => {
    const dialog = document.getElementById(opener.dataset.motionContextOpen);
    if (!dialog || typeof dialog.showModal !== "function") return;
    bindDialog(dialog);
    opener.addEventListener("click", () => showDialog(dialog, opener));
    if (new URLSearchParams(window.location.search).get(contextParameter) === dialog.id) {
      showDialog(dialog, null, false);
    }
  });
})();
