(() => {
  "use strict";

  const explainers = () => [...document.querySelectorAll(".motion-vote-explainer")];

  const syncScrollLock = () => {
    const isOpen = explainers().some((item) => item.classList.contains("is-open"));
    document.documentElement.classList.toggle("motion-vote-explainer-open", isOpen);
    document.body.classList.toggle("motion-vote-explainer-open", isOpen);
  };

  const close = (explainer) => {
    explainer.classList.remove("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "false");
    syncScrollLock();
  };

  const open = (explainer) => {
    explainers().forEach((item) => {
      if (item !== explainer) close(item);
    });
    explainer.classList.add("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "true");
    syncScrollLock();
  };

  explainers().forEach((explainer) => {
    const toggle = explainer.querySelector("[data-vote-explainer-toggle]");
    if (!toggle) return;
    toggle.addEventListener("click", (event) => {
      event.preventDefault();
      if (explainer.classList.contains("is-open")) close(explainer);
      else open(explainer);
    });
    explainer.querySelector("[data-vote-explainer-close]")?.addEventListener("click", () => close(explainer));
  });

  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest(".motion-vote-explainer")) explainers().forEach(close);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    explainers().forEach(close);
  });

  window.addEventListener("resize", syncScrollLock);
})();
