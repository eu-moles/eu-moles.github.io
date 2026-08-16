(() => {
  "use strict";

  const contextParameter = "context";
  const translationEndpoint = "https://translate.googleapis.com/translate_a/single";
  const translationCharacterLimit = 15000;

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

  const appendHighlightedText = (container, text) => {
    const expression = /\b(russ\p{L}*|ukrain\p{L}*|nato\b|belarus\p{L}*|iran\p{L}*|chin\p{L}*|korea\p{L}*)/giu;
    let lastIndex = 0;
    let match;
    while ((match = expression.exec(text)) !== null) {
      container.append(document.createTextNode(text.slice(lastIndex, match.index)));
      container.append(make("span", "red-marker", match[0]));
      lastIndex = expression.lastIndex;
    }
    container.append(document.createTextNode(text.slice(lastIndex)));
  };

  const appendProcedureText = (container, text, highlight = false) => {
    const expression = /(\d{4}\/\d{4}\([A-Z]{2,10}\))/g;
    let lastIndex = 0;
    let match;
    while ((match = expression.exec(text)) !== null) {
      const beforeReference = text.slice(lastIndex, match.index);
      if (highlight) appendHighlightedText(container, beforeReference);
      else container.append(document.createTextNode(beforeReference));
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
    const remainingText = text.slice(lastIndex);
    if (highlight) appendHighlightedText(container, remainingText);
    else container.append(document.createTextNode(remainingText));
  };

  const createTranslationButton = (language, text, translation) => {
    const code = String(language.code).toUpperCase();
    const button = make("button", "motion-context-language", code);
    button.type = "button";
    button.dataset.translationButton = "";
    button.dataset.translationCode = code;
    button.dataset.translationName = language.name || language.code;
    button.dataset.translationSource = String(language.code).toLowerCase();
    button.dataset.translationText = String(text || "");
    const cachedText = String(translation?.englishText || "");
    if (cachedText) {
      button.dataset.translationCached = cachedText;
      button.dataset.translated = "true";
      button.textContent = `${code} → EN`;
      button.title = `Machine-translated to English. Show original ${language.name || language.code} text.`;
      button.setAttribute("aria-label", `Show original ${language.name || language.code} text`);
      button.setAttribute("aria-pressed", "true");
    } else {
      button.title = `Original language: ${language.name || language.code}. Translate to English`;
      button.setAttribute("aria-label", `Translate ${language.name || language.code} to English`);
      button.setAttribute("aria-pressed", "false");
    }
    return button;
  };

  const translationText = (payload) => {
    if (!Array.isArray(payload?.[0])) throw new Error("Unexpected translation response");
    return payload[0]
      .map((segment) => Array.isArray(segment) ? segment[0] : "")
      .filter(Boolean)
      .join("");
  };

  const replaceBubbleText = (content, text, highlight = false) => {
    content.replaceChildren();
    String(text).split(/\n{2,}/).forEach((paragraph, index) => {
      if (index) content.append(document.createElement("br"), document.createElement("br"));
      appendProcedureText(content, paragraph, highlight);
    });
  };

  const translate = async (button) => {
    const bubble = button.closest(".motion-context-bubble");
    if (!bubble || button.dataset.translating === "true") return;
    const content = bubble.querySelector(".motion-context-bubble__text");
    if (!content) return;

    const code = button.dataset.translationCode || button.textContent;
    if (button.dataset.translated === "true") {
      if (typeof button._translationOriginalMarkup === "string") {
        content.innerHTML = button._translationOriginalMarkup;
      } else {
        replaceBubbleText(content, button.dataset.translationText || "", false);
      }
      button.textContent = code;
      button.title = `Original language: ${button.dataset.translationName || code}. Translate to English`;
      button.setAttribute("aria-label", `Translate ${button.dataset.translationName || code} to English`);
      button.setAttribute("aria-pressed", "false");
      delete button.dataset.translated;
      return;
    }

    const source = button.dataset.translationSource;
    const sourceText = button.dataset.translationText || "";
    if (!source || !sourceText) return;

    const cachedText = button.dataset.translationCached || "";
    if (cachedText) {
      button._translationOriginalMarkup = content.innerHTML;
      replaceBubbleText(content, cachedText, true);
      button.textContent = `${code} → EN`;
      button.title = "Machine-translated to English. Show original text.";
      button.setAttribute("aria-label", `Show original ${button.dataset.translationName || code} text`);
      button.setAttribute("aria-pressed", "true");
      button.dataset.translated = "true";
      return;
    }

    if (sourceText.length > translationCharacterLimit) {
      button.title = "Translation unavailable: this contribution is too long.";
      return;
    }

    button.dataset.translating = "true";
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    const originalLabel = button.textContent;
    let translated = false;
    button.textContent = "…";

    try {
      const url = new URL(translationEndpoint);
      url.searchParams.set("client", "gtx");
      url.searchParams.set("sl", source);
      url.searchParams.set("tl", "en");
      url.searchParams.set("dt", "t");
      url.searchParams.set("q", sourceText);
      const response = await fetch(url, { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`Translation request failed: ${response.status}`);
      button._translationOriginalMarkup = content.innerHTML;
      replaceBubbleText(content, translationText(await response.json()), true);
      button.textContent = `${code} → EN`;
      button.title = "Machine-translated to English by Google Translate. Show original text.";
      button.setAttribute("aria-label", `Show original ${button.dataset.translationName || code} text`);
      button.setAttribute("aria-pressed", "true");
      button.dataset.translated = "true";
      translated = true;
    } catch (error) {
      button.title = "English translation is currently unavailable. Please try again later.";
      console.warn("Discussion translation failed", error);
    } finally {
      if (!translated) button.textContent = originalLabel;
      button.disabled = false;
      button.removeAttribute("aria-busy");
      delete button.dataset.translating;
    }
  };

  const bindTranslationButton = (button) => {
    if (button.dataset.translationBound) return;
    button.dataset.translationBound = "true";
    button.addEventListener("click", () => translate(button));
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
    const title = make("h2");
    appendHighlightedText(title, String(motion.title || ""));
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
    note.append(languageIcon, document.createTextNode("Where available, remarks are machine-translated into English. Select the language badge to view the original."));

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
      const bubbleText = make("div", "motion-context-bubble__text");
      bubbleText.setAttribute("aria-live", "polite");
      const translatedText = String(turn.translation?.englishText || "");
      const displayedText = translatedText || String(turn.text || "");
      const highlightText = Boolean(translatedText) || !(turn.language && turn.language.code);
      displayedText.split(/\n{2,}/).forEach((paragraph, index) => {
        if (index) bubbleText.append(document.createElement("br"), document.createElement("br"));
        appendProcedureText(bubbleText, paragraph, highlightText);
      });
      bubble.append(bubbleText);
      if (turn.language && turn.language.code) {
        const language = createTranslationButton(turn.language, turn.text, turn.translation);
        bubble.append(language);
        bindTranslationButton(language);
      }
      content.append(speaker, bubble);
      turnElement.append(avatar, content);
      transcript.append(turnElement);
    });

    shell.append(header, note, transcript);
    if (motion.contextURL) {
      const footer = make("footer", "motion-context-modal__footer");
      const source = make("a", "", "Open the official transcript ");
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
    highlightText(container, text) {
      appendHighlightedText(container, String(text || ""));
    },
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

  document.querySelectorAll("[data-translation-button]").forEach(bindTranslationButton);
})();
