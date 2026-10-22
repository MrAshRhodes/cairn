(() => {
  "use strict";

  const spaces = {
    research: {
      name: "Research",
      selected: 0,
      split: false,
      pinned: new Set(["field-notes"]),
      pages: [
        {
          id: "field-notes",
          title: "Field notes",
          address: "fieldnotes.example / research",
          category: "FIELD NOTES / THE ART OF PAYING ATTENTION",
          heading: "Good ideas leave a trail.",
          deck: "A useful discovery rarely arrives alone. It comes with a reference, a half-formed question, and another page worth keeping open.",
          caption: "FIG. 01 / FOLLOW THE CONTOURS",
          excerpts: [
            ["Notice the connections.", "Keep the original source beside your notes. Small details often explain the bigger picture."],
            ["Leave yourself a way back.", "A good reading list is not a finish line. It is a collection of places to return to."],
          ],
          byline: "THE FIELD NOTES COLLECTION",
          readingTime: "4 MIN READ",
        },
        {
          id: "reading-list",
          title: "Reading list",
          address: "readingroom.example / collected",
          category: "READING ROOM / A WORK IN PROGRESS",
          heading: "Make space for the unexpected.",
          deck: "A collection of loose ends: a diagram that makes something click, a different explanation, a question without an answer yet.",
          caption: "FIG. 02 / THE PATH IS NOT A STRAIGHT LINE",
          excerpts: [
            ["Keep a small collection.", "Save the things that change your mind, not every page you happen to open."],
            ["Read across the edges.", "Follow one reference beyond the familiar. The most useful connection may be the least obvious."],
          ],
          byline: "NOTES FROM THE READING ROOM",
          readingTime: "3 MIN READ",
        },
        {
          id: "open-atlas",
          title: "Open atlas",
          address: "openatlas.example / contours",
          category: "OPEN ATLAS / LOOK A LITTLE CLOSER",
          heading: "The places between the places.",
          deck: "A map can tell you more than where to go. Trace the contours and you begin to see how a landscape fits together.",
          caption: "FIG. 03 / A STUDY IN CONTOURS",
          excerpts: [
            ["Read the empty space.", "The distance between two lines tells a story of its own. Slow down and look again."],
            ["Follow a different route.", "Landmarks help you navigate. The small details help you remember."],
          ],
          byline: "THE OPEN ATLAS COLLECTION",
          readingTime: "5 MIN READ",
        },
      ],
    },
    build: {
      name: "Build",
      selected: 0,
      split: false,
      pinned: new Set(["layout-lab"]),
      pages: [
        {
          id: "layout-lab",
          title: "Layout lab",
          address: "layoutlab.example / structure",
          category: "LAYOUT LAB / LESS, BUT CONSIDERED",
          heading: "Everything in its right place.",
          deck: "Start with the content. Give it a clear hierarchy, a little breathing room, and a structure that holds together as the window changes.",
          caption: "FIG. 01 / A FLEXIBLE FRAMEWORK",
          excerpts: [
            ["Work from the inside out.", "Let the smallest useful component tell you what the larger system needs."],
            ["Keep a reference close.", "Compare the intention with the implementation. Two views are often clearer than one."],
          ],
          byline: "LAYOUT LAB / WORKING NOTES",
          readingTime: "6 MIN READ",
        },
        {
          id: "system-notes",
          title: "System notes",
          address: "notebook.example / interfaces",
          category: "SYSTEM NOTES / SMALL, CLEAR INTERFACES",
          heading: "A small system, clearly described.",
          deck: "The best tools make their boundaries easy to understand. A few well-chosen pieces can do more than an elaborate collection of options.",
          caption: "FIG. 02 / SEPARATE THE CONCERNS",
          excerpts: [
            ["Name the responsibility.", "A component should have a job you can explain without listing all of its parts."],
            ["Make the edges explicit.", "Write down what comes in, what goes out, and what happens when something goes wrong."],
          ],
          byline: "THE BUILDER'S NOTEBOOK",
          readingTime: "4 MIN READ",
        },
      ],
    },
    weekend: {
      name: "Weekend",
      selected: 0,
      split: false,
      pinned: new Set(["north-coast"]),
      pages: [
        {
          id: "north-coast",
          title: "North coast",
          address: "coastguide.example / the-long-way",
          category: "NORTH COAST / AN UNHURRIED GUIDE",
          heading: "Take the longer way home.",
          deck: "A path beside the water, somewhere good to stop, and no particular need to get there quickly. A little room in the plan can be the best part.",
          caption: "FIG. 01 / FOLLOW THE SHORELINE",
          excerpts: [
            ["Leave the afternoon open.", "Choose a direction rather than a destination. There is plenty to notice along the way."],
            ["Keep the practical bits.", "Save a route, the opening hours, and somewhere to eat. Let the rest be a surprise."],
          ],
          byline: "THE WEEKEND COLLECTION",
          readingTime: "3 MIN READ",
        },
        {
          id: "trail-journal",
          title: "Trail journal",
          address: "trailjournal.example / small-detours",
          category: "TRAIL JOURNAL / SMALL DETOURS",
          heading: "Somewhere just around the bend.",
          deck: "Good walks are made of small discoveries: a quiet turn, a different view, a place you might have passed without noticing.",
          caption: "FIG. 02 / LEAVE A LITTLE ROOM",
          excerpts: [
            ["Look up from the route.", "A plan gets you started. Paying attention makes the journey yours."],
            ["Bring back a detail.", "A few words are enough to remember a place. Note what you would like to find again."],
          ],
          byline: "NOTES FROM THE TRAIL",
          readingTime: "2 MIN READ",
        },
      ],
    },
  };

  const tabList = document.getElementById("tab-list");
  const pagePanel = document.getElementById("sample-page");
  const pageContent = document.getElementById("page-content");
  const splitPane = document.getElementById("split-pane");
  const workspace = document.getElementById("page-workspace");
  const pinnedList = document.getElementById("pinned-list");
  const pinButton = document.querySelector("[data-pin]");
  const splitButton = document.querySelector("[data-split]");
  const liveStatus = document.getElementById("workspace-status");
  const commandDialog = document.getElementById("command-dialog");
  const commandInput = document.getElementById("command-input");
  const commandList = document.getElementById("command-list");
  let activeSpace = "research";
  let filteredCommands = [];
  let selectedCommand = -1;
  let returnFocus = null;

  const pinIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 3 6 0-1 5 3 4H5l3-4-1-5ZM10 12v5"></path></svg>';
  const commandIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 10h13m-5-5 5 5-5 5"></path></svg>';

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function currentPage() {
    return spaces[activeSpace].pages[spaces[activeSpace].selected];
  }

  function renderPage(container, page) {
    const metadata = element("p", "page-metadata", page.category);
    const title = element("h3", "sample-title", page.heading);
    const deck = element("p", "page-deck", page.deck);
    const illustration = element("div", `contour-card art-${activeSpace}`);
    illustration.setAttribute("aria-hidden", "true");
    illustration.append(element("span", "contour-label", page.caption));
    const excerpts = element("div", "page-excerpt");
    for (const [heading, text] of page.excerpts) {
      const paragraph = element("p");
      paragraph.append(element("strong", "", heading), document.createTextNode(` ${text}`));
      excerpts.append(paragraph);
    }
    const byline = element("div", "page-byline");
    byline.append(element("span", "", page.byline), element("span", "", page.readingTime));
    container.replaceChildren(metadata, title, deck, illustration, excerpts, byline);
  }

  function renderWorkspace(focusTab = false) {
    const space = spaces[activeSpace];
    const page = currentPage();
    document.querySelectorAll("[data-space]").forEach((button) => {
      const selected = button.dataset.space === activeSpace;
      button.classList.toggle("is-active", selected);
      button.setAttribute("aria-pressed", String(selected));
    });
    tabList.setAttribute("aria-label", `Pages in the ${space.name} Space`);
    document.getElementById("page-count").textContent = String(space.pages.length).padStart(2, "0");
    tabList.replaceChildren();
    space.pages.forEach((item, index) => {
      const tab = element("button", "tab");
      tab.type = "button";
      tab.id = `tab-${item.id}`;
      tab.dataset.page = String(index);
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", String(index === space.selected));
      tab.setAttribute("aria-controls", "sample-page");
      tab.tabIndex = index === space.selected ? 0 : -1;
      const favicon = element("span", "tab-favicon", item.title.charAt(0));
      favicon.setAttribute("aria-hidden", "true");
      tab.append(favicon, element("span", "", item.title));
      if (space.pinned.has(item.id)) {
        const marker = element("span", "tab-pin", "•");
        marker.setAttribute("aria-hidden", "true");
        tab.append(marker);
        tab.setAttribute("aria-label", `${item.title}, pinned`);
      }
      tabList.append(tab);
    });
    document.getElementById("address-text").textContent = page.address;
    pagePanel.setAttribute("aria-labelledby", `tab-${page.id}`);
    renderPage(pageContent, page);
    renderPins();
    pinButton.setAttribute("aria-pressed", String(space.pinned.has(page.id)));
    pinButton.setAttribute("aria-label", space.pinned.has(page.id) ? "Unpin this page" : "Pin this page");
    pinButton.title = pinButton.getAttribute("aria-label");
    splitButton.setAttribute("aria-pressed", String(space.split));
    splitButton.setAttribute("aria-label", space.split ? "Close split view" : "Open split view");
    splitButton.title = splitButton.getAttribute("aria-label");
    splitPane.hidden = !space.split;
    workspace.classList.toggle("has-split", space.split);
    if (space.split) {
      const secondPage = space.pages[(space.selected + 1) % space.pages.length];
      const content = element("div", "page-content");
      renderPage(content, secondPage);
      splitPane.replaceChildren(content);
      splitPane.setAttribute("aria-label", `Second sample page: ${secondPage.title}`);
    }
    document.getElementById("space-status").textContent = `${space.name.toUpperCase()} / ${String(space.selected + 1).padStart(2, "0")}`;
    if (focusTab) document.getElementById(`tab-${page.id}`).focus();
  }

  function renderPins() {
    const space = spaces[activeSpace];
    pinnedList.replaceChildren();
    document.getElementById("pin-count").textContent = String(space.pinned.size).padStart(2, "0");
    space.pages.forEach((page, index) => {
      if (!space.pinned.has(page.id)) return;
      const button = element("button", "pinned-link");
      button.type = "button";
      button.dataset.page = String(index);
      button.innerHTML = pinIcon;
      button.append(element("span", "", page.title));
      pinnedList.append(button);
    });
    if (!space.pinned.size) {
      pinnedList.append(element("p", "pinned-empty", "Pin a page to keep it here."));
    }
  }

  function selectSpace(id) {
    activeSpace = id;
    renderWorkspace();
    liveStatus.textContent = `${spaces[id].name} Space. ${spaces[id].pages.length} sample pages.`;
  }

  function togglePin() {
    const space = spaces[activeSpace];
    const page = currentPage();
    if (space.pinned.has(page.id)) space.pinned.delete(page.id);
    else space.pinned.add(page.id);
    renderWorkspace();
    liveStatus.textContent = `${page.title} ${space.pinned.has(page.id) ? "pinned" : "unpinned"} in ${space.name}.`;
  }

  function toggleSplit() {
    const space = spaces[activeSpace];
    space.split = !space.split;
    renderWorkspace();
    liveStatus.textContent = space.split ? "Split view opened. Two sample pages are visible." : "Split view closed.";
  }

  function getCommands() {
    const page = currentPage();
    const space = spaces[activeSpace];
    return [
      ...Object.entries(spaces).map(([id, item]) => ({
        label: `Go to ${item.name} Space`,
        keywords: "switch workspace",
        run: () => selectSpace(id),
      })),
      {
        label: `${space.pinned.has(page.id) ? "Unpin" : "Pin"} ${page.title}`,
        keywords: "save keep bookmark",
        run: togglePin,
      },
      {
        label: space.split ? "Close split view" : "Open split view",
        keywords: "compare side by side",
        run: toggleSplit,
      },
      ...space.pages.map((item, index) => ({
        label: `Open ${item.title}`,
        keywords: item.address,
        run: () => {
          space.selected = index;
          renderWorkspace();
          liveStatus.textContent = `${item.title} opened in ${space.name}.`;
        },
      })),
    ];
  }

  function selectCommand(index) {
    selectedCommand = index;
    [...commandList.children].forEach((option, optionIndex) => {
      option.setAttribute("aria-selected", String(optionIndex === index));
    });
    if (index >= 0) {
      commandInput.setAttribute("aria-activedescendant", `command-${index}`);
      commandList.children[index].scrollIntoView({ block: "nearest" });
    } else {
      commandInput.removeAttribute("aria-activedescendant");
    }
  }

  function renderCommands() {
    const query = commandInput.value.trim().toLowerCase();
    filteredCommands = getCommands().filter((command) => `${command.label} ${command.keywords}`.toLowerCase().includes(query));
    commandList.replaceChildren();
    filteredCommands.forEach((command, index) => {
      const option = element("div", "command-option");
      option.id = `command-${index}`;
      option.dataset.command = String(index);
      option.setAttribute("role", "option");
      option.innerHTML = commandIcon;
      option.append(element("span", "", command.label));
      commandList.append(option);
    });
    document.getElementById("command-empty").hidden = filteredCommands.length > 0;
    selectCommand(filteredCommands.length ? 0 : -1);
  }

  function openCommands() {
    returnFocus = document.activeElement;
    commandInput.value = "";
    commandDialog.showModal();
    document.body.classList.add("command-open");
    renderCommands();
    commandInput.focus();
  }

  function runCommand(index) {
    const command = filteredCommands[index];
    if (!command) return;
    commandDialog.close();
    command.run();
  }

  document.querySelectorAll("[data-space]").forEach((button) => {
    button.addEventListener("click", () => selectSpace(button.dataset.space));
  });
  tabList.addEventListener("click", (event) => {
    const tab = event.target.closest("[data-page]");
    if (!tab) return;
    spaces[activeSpace].selected = Number(tab.dataset.page);
    renderWorkspace(true);
  });
  tabList.addEventListener("keydown", (event) => {
    const space = spaces[activeSpace];
    const vertical = tabList.getAttribute("aria-orientation") === "vertical";
    let index = space.selected;
    if (event.key === (vertical ? "ArrowDown" : "ArrowRight")) index = (index + 1) % space.pages.length;
    else if (event.key === (vertical ? "ArrowUp" : "ArrowLeft")) index = (index + space.pages.length - 1) % space.pages.length;
    else if (event.key === "Home") index = 0;
    else if (event.key === "End") index = space.pages.length - 1;
    else return;
    event.preventDefault();
    space.selected = index;
    renderWorkspace(true);
  });
  pinnedList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-page]");
    if (!button) return;
    spaces[activeSpace].selected = Number(button.dataset.page);
    renderWorkspace(true);
  });
  pinButton.addEventListener("click", togglePin);
  splitButton.addEventListener("click", toggleSplit);
  document.querySelectorAll("[data-command-open]").forEach((button) => button.addEventListener("click", openCommands));
  document.querySelector("[data-command-close]").addEventListener("click", () => commandDialog.close());
  commandInput.addEventListener("input", renderCommands);
  commandInput.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!filteredCommands.length) return;
      const direction = event.key === "ArrowDown" ? 1 : -1;
      selectCommand((selectedCommand + direction + filteredCommands.length) % filteredCommands.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      runCommand(selectedCommand);
    }
  });
  commandList.addEventListener("click", (event) => {
    const option = event.target.closest("[data-command]");
    if (option) runCommand(Number(option.dataset.command));
  });
  commandList.addEventListener("pointermove", (event) => {
    const option = event.target.closest("[data-command]");
    if (option && Number(option.dataset.command) !== selectedCommand) selectCommand(Number(option.dataset.command));
  });
  commandDialog.addEventListener("click", (event) => {
    if (event.target === commandDialog) commandDialog.close();
  });
  commandDialog.addEventListener("close", () => {
    document.body.classList.remove("command-open");
    if (returnFocus instanceof HTMLElement && returnFocus.isConnected) returnFocus.focus();
    else document.querySelector(`[data-space="${activeSpace}"]`).focus();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "k") {
      event.preventDefault();
      if (commandDialog.open) commandDialog.close();
      else openCommands();
    }
  });

  const mobileLayout = window.matchMedia("(max-width: 700px)");
  function updateTabOrientation() {
    tabList.setAttribute("aria-orientation", mobileLayout.matches ? "horizontal" : "vertical");
  }
  mobileLayout.addEventListener("change", updateTabOrientation);
  updateTabOrientation();
  renderWorkspace();
})();
