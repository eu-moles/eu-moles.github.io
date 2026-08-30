(() => {
  "use strict";

  const iconSelector = ".fa-arrow-up-right-from-square";

  const isExternal = (link) => {
    const href = link.getAttribute("href");
    if (!href) return false;

    try {
      const url = new URL(href, document.baseURI);
      return (url.protocol === "http:" || url.protocol === "https:")
        && url.origin !== window.location.origin;
    } catch {
      return false;
    }
  };

  const decorate = (link) => {
    if (!isExternal(link) || link.querySelector(iconSelector)) return;

    const icon = document.createElement("i");
    icon.className = "fa-solid fa-arrow-up-right-from-square";
    icon.setAttribute("aria-hidden", "true");
    link.append(document.createTextNode(" "), icon);
  };

  const decorateTree = (root) => {
    if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return;
    if (root.matches?.("a[href]")) decorate(root);
    root.querySelectorAll?.("a[href]").forEach(decorate);
  };

  const initialise = () => {
    decorateTree(document);

    new MutationObserver((records) => {
      records.forEach((record) => {
        if (record.type === "attributes") {
          decorate(record.target);
          return;
        }
        record.addedNodes.forEach(decorateTree);
      });
    }).observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["href"],
    });
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialise, { once: true });
  else initialise();
})();
