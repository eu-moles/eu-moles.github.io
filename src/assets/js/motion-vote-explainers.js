(() => {
  "use strict";

  const explainers = () => [...document.querySelectorAll(".motion-vote-explainer")];

  const close = (explainer) => {
    explainer.classList.remove("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "false");
  };

  const open = (explainer) => {
    explainers().forEach((item) => {
      if (item !== explainer) close(item);
    });
    explainer.classList.add("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "true");
  };

  explainers().forEach((explainer) => {
    const toggle = explainer.querySelector("[data-vote-explainer-toggle]");
    if (!toggle) return;
    toggle.addEventListener("click", (event) => {
      event.preventDefault();
      if (explainer.classList.contains("is-open")) close(explainer);
      else open(explainer);
    });
  });

  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest(".motion-vote-explainer")) explainers().forEach(close);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    explainers().forEach(close);
  });
})();
