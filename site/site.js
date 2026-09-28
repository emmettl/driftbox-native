// The page's few moving parts: the scenes' gallery, a way to hear the muted clip, and the downloads,
// read from the repository's releases as each platform's build is published.
(() => {
  const repo = "emmettl/driftbox-native";

  // The scenes, by the names the app gives them. Longhand is left out, being a blank page until
  // someone draws on it, and Pulse, the plain one every other stands in for.
  const scenes = [
    ["web", "Web"], ["cubik", "Cubik"], ["nightbus", "Night Bus"], ["saturn", "Saturn"],
    ["sunset", "Sunset"], ["papercities", "Paper Cities"], ["daydream", "Daydream"],
    ["smallhours", "Small Hours"], ["water", "Stillwater"], ["cycles", "Light Cycles"],
    ["lifeforms", "Lifeforms"], ["graphic", "Graphic Lab"], ["weave", "Weave"], ["defcon", "Defcon"],
    ["clouds", "Clouds"], ["dancers", "Dancers"], ["machine", "Machine"], ["hothouse", "Hothouse"],
    ["wireframe", "Wireframe"], ["jumpman", "Jump Man"], ["switchback", "Switchback"],
    ["trench", "Trench"], ["convoy", "Endless Convoy"], ["orrery", "Orrery"], ["frost", "Frost"],
  ];
  const gallery = document.querySelector("[data-gallery]");
  if (gallery) {
    for (const [id, name] of scenes) {
      const item = document.createElement("li");
      const image = document.createElement("img");
      image.src = `media/scenes/${id}.webp`;
      image.alt = `The ${name} scene`;
      image.loading = "lazy";
      image.width = 640;
      image.height = 360;
      const label = document.createElement("span");
      label.textContent = name;
      item.append(image, label);
      gallery.append(item);
    }
  }

  // The opening clip plays muted, as browsers insist; a button hears it, from the top. And for
  // someone who has asked for less motion, it waits to be played.
  for (const player of document.querySelectorAll("[data-player]")) {
    const video = player.querySelector("video");
    const sound = player.querySelector("[data-sound]");
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches && video.autoplay) {
      video.removeAttribute("autoplay");
      video.pause();
      video.controls = true;
    }
    // Some browsers hold back a muted clip's autoplay until asked again.
    if (video.autoplay) {
      video.addEventListener("loadeddata", () => {
        if (video.paused) video.play().catch(() => {});
      }, { once: true });
    }
    if (!sound) continue;
    sound.addEventListener("click", () => {
      const hearing = video.muted;
      video.muted = !hearing;
      if (hearing) {
        video.currentTime = 0;
        video.play().catch(() => {});
      }
      sound.textContent = hearing ? "Sound off" : "Sound on";
      sound.setAttribute("aria-pressed", String(hearing));
    });
  }

  // The platform this page is being read on, as well as a browser will say.
  const agent = navigator.userAgent;
  const yours = /Android/i.test(agent) ? "android"
    : /Windows/i.test(agent) ? "windows"
    : /Mac OS X|Macintosh/i.test(agent) && !/iPhone|iPad/i.test(agent) ? "mac"
    : /Linux|X11/i.test(agent) ? "linux"
    : null;
  if (yours) document.querySelector(`[data-platform="${yours}"]`)?.classList.add("yours");

  // What each platform's files are called, as the release scripts name them, and what to call them.
  const kinds = {
    mac: [[/macos.*\.(zip|dmg)$/i, "Download for Mac"]],
    windows: [[/setup.*\.exe$/i, "Installer"], [/windows.*\.zip$/i, "Portable .zip"]],
    android: [[/\.apk$/i, "Download .apk"]],
    linux: [[/(amd64|x86_64).*\.deb$|\.(amd64|x86_64)\.deb$/i, ".deb for x86-64"],
      [/(arm64|aarch64).*\.deb$|\.(arm64|aarch64)\.deb$/i, ".deb for Arm"]],
  };

  function show(releases) {
    let any = false;
    for (const [platform, patterns] of Object.entries(kinds)) {
      const links = document.querySelector(`[data-platform="${platform}"] [data-links]`);
      // The newest release with something for this platform: they need not all ship together.
      let found = null;
      for (const release of releases) {
        const assets = patterns
          .map(([pattern, label]) => [release.assets.find((asset) => pattern.test(asset.name)), label])
          .filter(([asset]) => asset);
        if (assets.length) {
          found = { release, assets };
          break;
        }
      }
      links.replaceChildren();
      if (!found) {
        const soon = document.createElement("span");
        soon.className = "soon";
        soon.textContent = "Not released yet";
        links.append(soon);
        continue;
      }
      any = true;
      for (const [asset, label] of found.assets) {
        const link = document.createElement("a");
        link.className = "button primary";
        link.href = asset.browser_download_url;
        link.textContent = label;
        links.append(link);
      }
      const version = document.createElement("a");
      version.className = "version";
      version.href = found.release.html_url;
      version.textContent = `${found.release.name || found.release.tag_name}${found.release.prerelease ? " (preview)" : ""}`;
      links.append(version);
    }
    if (any) {
      document.querySelector("[data-release-status]").textContent =
        "The newest build for each platform. Driftbox is free and open source.";
    }
  }

  function notYet() {
    for (const links of document.querySelectorAll("[data-links]")) {
      if (links.childElementCount) continue;
      const soon = document.createElement("span");
      soon.className = "soon";
      soon.textContent = "Not released yet";
      links.append(soon);
    }
  }

  // Asked once a visit: GitHub allows a browser sixty questions an hour.
  const key = "driftbox.releases";
  let kept = null;
  try {
    kept = JSON.parse(sessionStorage.getItem(key) || "null");
  } catch {}
  if (kept) {
    show(kept);
  } else {
    fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
      .then((all) => {
        const published = all
          .filter((release) => !release.draft)
          .map(({ name, tag_name, prerelease, html_url, assets }) => ({
            name, tag_name, prerelease, html_url,
            assets: assets.map(({ name, browser_download_url }) => ({ name, browser_download_url })),
          }));
        try {
          sessionStorage.setItem(key, JSON.stringify(published));
        } catch {}
        show(published);
      })
      .catch(notYet);
  }
})();
