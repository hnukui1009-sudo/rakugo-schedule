const FAVORITES_KEY = "rakugo-schedule-favorites";

const state = {
  events: [],
  updatedAt: null,
  filteredEvents: [],
  favorites: loadFavorites(),
  selectedId: null,
  performersById: {},
  performersByName: {},
  performerDirectoryUpdatedAt: null,
};

const els = {
  filters: document.getElementById("filters"),
  keyword: document.getElementById("keyword"),
  category: document.getElementById("category"),
  venue: document.getElementById("venue"),
  area: document.getElementById("area"),
  quickRange: document.getElementById("quickRange"),
  favoritesOnly: document.getElementById("favoritesOnly"),
  eventList: document.getElementById("event-list"),
  detail: document.getElementById("event-detail"),
  status: document.getElementById("status"),
  resultSummary: document.getElementById("result-summary"),
  statCount: document.getElementById("stat-count"),
  lastUpdated: document.getElementById("last-updated"),
  footerSpotlightContent: document.getElementById("footer-spotlight-content"),
};

document.addEventListener("DOMContentLoaded", init);

async function init() {
  setStatus("公演データを読み込んでいます。");

  const payload = await loadEventPayload();
  const performerPayload = await loadPerformerPayload();
  state.events = sortEvents(payload.events || []);
  state.filteredEvents = [...state.events];
  state.updatedAt = payload.updatedAt || null;
  state.selectedId = state.events[0]?.id || null;
  state.performersById = indexPerformersById(performerPayload.performers || []);
  state.performersByName = indexPerformersByName(performerPayload.performers || []);
  state.performerDirectoryUpdatedAt = performerPayload.fetchedAt || null;

  populateSelectOptions("category", uniqueValues(state.events, "categoryLabel"));
  populateSelectOptions("venue", uniqueValues(state.events, "venueName"));
  populateSelectOptions("area", uniqueValues(state.events, "area"));

  els.filters.addEventListener("input", applyFilters);
  els.filters.addEventListener("change", applyFilters);
  els.filters.addEventListener("reset", () => {
    requestAnimationFrame(() => {
      els.quickRange.value = "all";
      applyFilters();
    });
  });

  renderMeta();
  applyFilters();
  renderFooterSpotlight();
}

async function loadEventPayload() {
  const embedded = readEmbeddedEvents();

  try {
    const response = await fetch("./events.json", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    setStatus("最新の JSON データを読み込みました。");
    return payload;
  } catch (error) {
    setStatus("ローカル表示用の埋め込みデータを使っています。");
    return embedded;
  }
}

async function loadPerformerPayload() {
  const embedded = readEmbeddedPerformers();

  try {
    const response = await fetch("./performers.json", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } catch (error) {
    return embedded;
  }
}

function readEmbeddedEvents() {
  const node = document.getElementById("embedded-events");
  return JSON.parse(node.textContent);
}

function readEmbeddedPerformers() {
  const node = document.getElementById("embedded-performers");
  if (!node) {
    return { performers: [] };
  }

  return JSON.parse(node.textContent);
}

function applyFilters() {
  const keyword = els.keyword.value.trim().toLowerCase();
  const category = els.category.value;
  const venue = els.venue.value;
  const area = els.area.value;
  const quickRange = els.quickRange.value;
  const favoritesOnly = els.favoritesOnly.checked;
  const now = startOfDay(new Date());

  state.filteredEvents = state.events.filter((event) => {
    const searchable = [
      event.title,
      event.venueName,
      event.area,
      event.categoryLabel,
      ...(event.performers || []),
    ]
      .join(" ")
      .toLowerCase();

    if (keyword && !searchable.includes(keyword)) {
      return false;
    }
    if (category && event.categoryLabel !== category) {
      return false;
    }
    if (venue && event.venueName !== venue) {
      return false;
    }
    if (area && event.area !== area) {
      return false;
    }
    if (favoritesOnly && !state.favorites.includes(event.id)) {
      return false;
    }
    if (!matchesQuickRange(event.startAt, quickRange, now)) {
      return false;
    }

    return true;
  });

  if (!state.filteredEvents.some((event) => event.id === state.selectedId)) {
    state.selectedId = state.filteredEvents[0]?.id || null;
  }

  renderMeta();
  renderList();
  renderDetail();
}

function matchesQuickRange(startAt, quickRange, now) {
  if (quickRange === "all") {
    return true;
  }

  const eventDay = startOfDay(new Date(startAt));

  if (quickRange === "today") {
    return eventDay.getTime() === now.getTime();
  }

  if (quickRange === "week") {
    const weekEnd = new Date(now);
    weekEnd.setDate(weekEnd.getDate() + 6);
    return eventDay >= now && eventDay <= weekEnd;
  }

  if (quickRange === "weekend") {
    const weekend = getUpcomingWeekend(now);
    return eventDay >= weekend.start && eventDay <= weekend.end;
  }

  return true;
}

function renderMeta() {
  els.statCount.textContent = `${state.filteredEvents.length}件`;
  els.lastUpdated.textContent = state.updatedAt
    ? formatDateTime(state.updatedAt)
    : "未設定";

  const total = state.events.length;
  const shown = state.filteredEvents.length;
  els.resultSummary.textContent = `${shown} / ${total} 件を表示`;
}

function renderList() {
  if (!state.filteredEvents.length) {
    els.eventList.innerHTML =
      '<div class="empty-state"><p>条件に合う公演が見つかりませんでした。絞り込みを少しゆるめてみてください。</p></div>';
    return;
  }

  els.eventList.innerHTML = state.filteredEvents
    .map((event) => {
      const isFavorite = state.favorites.includes(event.id);
      const isActive = state.selectedId === event.id;
      const featuredPerformers = getFeaturedPerformers(event);
      const headliner = featuredPerformers[0];
      return `
        <article class="event-card ${isActive ? "is-active" : ""}" data-id="${escapeHtml(event.id)}">
          <div class="event-card__top">
            <div>
              <p class="event-card__category">${escapeHtml(event.categoryLabel)}</p>
              <h3 class="event-card__title">${escapeHtml(event.title)}</h3>
              ${
                headliner
                  ? `
                    <div class="event-card__headliner">
                      <span>本日の見どころ</span>
                      <strong>${escapeHtml(headliner.displayName)}</strong>
                    </div>
                  `
                  : ""
              }
            </div>
            <button class="event-card__favorite ${isFavorite ? "is-favorite" : ""}" type="button" data-favorite-id="${escapeHtml(event.id)}" aria-label="お気に入り切り替え">
              ${isFavorite ? "★" : "☆"}
            </button>
          </div>
          <div class="event-card__meta">
            <span class="badge">${escapeHtml(formatDate(event.startAt))}</span>
            <span class="badge">${escapeHtml(formatTimeRange(event.startAt, event.endAt))}</span>
            <span class="badge">${escapeHtml(event.venueName)}</span>
            <span class="badge">${escapeHtml(event.area || "エリア未設定")}</span>
          </div>
          <p class="event-card__desc">${escapeHtml(event.description || "詳細説明は未設定です。")}</p>
          ${
            featuredPerformers.length
              ? `
                <div class="event-card__featured">
                  <p class="event-card__featured-label">出演者</p>
                  <div class="performer-tags">
                    ${featuredPerformers.map((performer) => renderPerformerTag(performer)).join("")}
                  </div>
                </div>
              `
              : ""
          }
          <div class="event-card__actions">
            <a class="link-button link-button--primary" href="${escapeAttribute(event.sourceURL)}" target="_blank" rel="noreferrer">公式ページ</a>
          </div>
        </article>
      `;
    })
    .join("");

  els.eventList.querySelectorAll(".event-card").forEach((card) => {
    card.addEventListener("click", (event) => {
      if (event.target.closest("[data-favorite-id], a, button")) {
        return;
      }
      state.selectedId = card.dataset.id;
      renderList();
      renderDetail();
    });
  });

  els.eventList.querySelectorAll("[data-favorite-id]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      toggleFavorite(button.dataset.favoriteId);
    });
  });
}

function renderDetail() {
  const event = state.events.find((item) => item.id === state.selectedId);

  if (!event) {
    els.detail.className = "detail empty-detail";
    els.detail.innerHTML = "<p>気になる公演を選ぶと、ここに詳しい情報が出ます。</p>";
    return;
  }

  const performerCards = getEventPerformers(event)
    .map((performer) => {
      const subtitle = [performer.category, performer.birthPlace].filter(Boolean).join(" / ");
      return `
        <article class="performer-card">
          <p class="event-card__category">出演者補足</p>
          <h4>${escapeHtml(performer.displayName)}</h4>
          <p class="performer-card__meta">${escapeHtml(subtitle || "落語協会プロフィール")}</p>
          <p class="performer-card__body">${escapeHtml(performer.shortBio || "落語協会のプロフィールページを参照できます。")}</p>
          <div class="performer-card__tags">
            ${performer.debayashi ? `<span class="badge">出囃子 ${escapeHtml(performer.debayashi)}</span>` : ""}
            ${performer.crest ? `<span class="badge">紋 ${escapeHtml(performer.crest)}</span>` : ""}
          </div>
          <div class="detail__actions">
            <a class="link-button link-button--secondary" href="${escapeAttribute(performer.profileURL)}">落語協会プロフィール</a>
            ${
              performer.websiteURL
                ? `<a class="link-button link-button--secondary" href="${escapeAttribute(performer.websiteURL)}">公式サイト</a>`
                : ""
            }
          </div>
        </article>
      `;
    })
    .join("");

  els.detail.className = "detail";
  els.detail.innerHTML = `
    <section class="detail__header">
      <p class="event-card__category">${escapeHtml(event.categoryLabel)}</p>
      <h3>${escapeHtml(event.title)}</h3>
      <p class="detail__lead">${escapeHtml(event.description || "説明は未設定です。")}</p>
    </section>
    <section class="detail__meta">
      ${detailRow("日時", `${formatDate(event.startAt)} ${formatTimeRange(event.startAt, event.endAt)}`)}
      ${detailRow("会場", `${event.venueName}${event.venueAddress ? ` / ${event.venueAddress}` : ""}`)}
      ${detailRowHtml("出演者", renderDetailPerformers(event))}
      ${detailRow("料金", event.priceText || "未設定")}
      ${detailRow("取得元", event.sourceName || "未設定")}
      ${detailRow("最終確認", formatDateTime(event.lastConfirmedAt || event.fetchedAt))}
      ${detailRow("出演者DB更新", state.performerDirectoryUpdatedAt ? formatDateTime(state.performerDirectoryUpdatedAt) : "未読込")}
    </section>
    <div class="detail__actions">
      <a class="link-button link-button--primary" href="${escapeAttribute(event.sourceURL)}" target="_blank" rel="noreferrer">公式ページへ</a>
    </div>
    ${performerCards ? `<section class="performer-grid">${performerCards}</section>` : ""}
  `;
}

function detailRow(label, value) {
  return `
    <div class="detail__row">
      <span class="detail__label">${escapeHtml(label)}</span>
      <strong class="detail__value">${escapeHtml(value)}</strong>
    </div>
  `;
}

function detailRowHtml(label, html) {
  return `
    <div class="detail__row">
      <span class="detail__label">${escapeHtml(label)}</span>
      <div class="detail__value">${html}</div>
    </div>
  `;
}

function toggleFavorite(id) {
  if (state.favorites.includes(id)) {
    state.favorites = state.favorites.filter((favoriteId) => favoriteId !== id);
  } else {
    state.favorites = [...state.favorites, id];
  }

  saveFavorites(state.favorites);
  applyFilters();
}

function populateSelectOptions(id, values) {
  const select = els[id];
  const current = select.innerHTML;
  select.innerHTML =
    current +
    values
      .map((value) => `<option value="${escapeAttribute(value)}">${escapeHtml(value)}</option>`)
      .join("");
}

function getEventPerformers(event) {
  const ids = Array(event.performerIds || []);
  if (ids.length) {
    return ids
      .map((id) => state.performersById[id])
      .filter(Boolean);
  }

  return Array(event.performers || [])
    .map((name) => state.performersByName[normalizeName(name)])
    .filter(Boolean);
}

function getFeaturedPerformers(event) {
  const shinuchi = getEventPerformers(event).filter(
    (performer) => Array(performer.ranks || []).includes("真打") && performer.status !== "deceased"
  );

  if (shinuchi.length) {
    return shinuchi.slice(-3).reverse();
  }

  return Array(event.performers || [])
    .slice(-3)
    .reverse()
    .map((name) => state.performersByName[normalizeName(name)])
    .filter(Boolean);
}

function renderDetailPerformers(event) {
  const knownPerformers = getEventPerformers(event);
  const byName = new Map(
    knownPerformers.map((performer) => [normalizeName(performer.displayName), performer])
  );
  const performerNames = Array(event.performers || []);

  if (!performerNames.length) {
    return "<strong>未設定</strong>";
  }

  return `
    <div class="performer-tags performer-tags--detail">
      ${performerNames
        .map((name) => {
          const performer = byName.get(normalizeName(name));
          return performer
            ? renderPerformerTag(performer, {
                showPopupRank: true,
                showPopupLink: true,
                compact: true,
                popupCentered: true,
              })
            : `<span class="performer-tag performer-tag--plain"><span class="performer-tag__name">${escapeHtml(name)}</span></span>`;
        })
        .join("")}
    </div>
  `;
}

function renderPerformerTag(performer, options = {}) {
  const bio = performer.shortBio || "落語協会プロフィールを参照できます。";
  const age = formatPerformerAge(performer.birthDate);
  const rank = Array(performer.ranks || []).join(" / ") || performer.category || "出演者";
  const homepageUrl = performer.websiteURL || performer.profileURL || "";
  const homepageLabel = performer.websiteURL ? "ホームページへ" : "プロフィールページへ";

  return `
    <span class="performer-tag${options.compact ? " performer-tag--compact" : ""}${options.popupCentered ? " performer-tag--popup-centered" : ""}" tabindex="0">
      ${options.compact ? "" : `<span class="performer-tag__role">${escapeHtml(rank)}</span>`}
      <span class="performer-tag__name">${escapeHtml(performer.displayName)}</span>
      <span class="performer-tag__popup" role="tooltip">
        <strong>${escapeHtml(performer.displayName)}</strong>
        <span>${escapeHtml(bio)}</span>
        <span>年齢: ${escapeHtml(age)}</span>
        ${options.showPopupRank ? `<span>階級: ${escapeHtml(rank)}</span>` : ""}
        ${
          options.showPopupLink && homepageUrl
            ? `<a class="performer-tag__link" href="${escapeAttribute(homepageUrl)}" target="_blank" rel="noreferrer">${escapeHtml(homepageLabel)}</a>`
            : ""
        }
      </span>
    </span>
  `;
}

function indexPerformersById(performers) {
  return performers.reduce((acc, performer) => {
    acc[performer.id] = performer;
    return acc;
  }, {});
}

function indexPerformersByName(performers) {
  return performers.reduce((acc, performer) => {
    acc[normalizeName(performer.displayName)] = performer;
    return acc;
  }, {});
}

function uniqueValues(events, key) {
  return [...new Set(events.map((event) => event[key]).filter(Boolean))].sort((a, b) =>
    a.localeCompare(b, "ja")
  );
}

function sortEvents(events) {
  return [...events].sort((a, b) => new Date(a.startAt) - new Date(b.startAt));
}

function startOfDay(date) {
  const clone = new Date(date);
  clone.setHours(0, 0, 0, 0);
  return clone;
}

function getUpcomingWeekend(date) {
  const start = startOfDay(date);
  const day = start.getDay();
  const offsetToSaturday = day <= 6 ? (6 - day) % 7 : 0;
  const saturday = new Date(start);
  saturday.setDate(saturday.getDate() + offsetToSaturday);
  const sunday = new Date(saturday);
  sunday.setDate(sunday.getDate() + 1);
  sunday.setHours(23, 59, 59, 999);
  return { start: saturday, end: sunday };
}

function formatDate(value) {
  return new Intl.DateTimeFormat("ja-JP", {
    month: "numeric",
    day: "numeric",
    weekday: "short",
  }).format(new Date(value));
}

function formatDateTime(value) {
  return new Intl.DateTimeFormat("ja-JP", {
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function formatTimeRange(startAt, endAt) {
  const formatter = new Intl.DateTimeFormat("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
  });
  const start = formatter.format(new Date(startAt));
  if (!endAt) {
    return `${start} 開演`;
  }
  return `${start} - ${formatter.format(new Date(endAt))}`;
}

function formatPerformerAge(birthDate) {
  if (!birthDate) {
    return "不明";
  }

  const birth = new Date(birthDate);
  const today = new Date();
  let age = today.getFullYear() - birth.getFullYear();
  const hasHadBirthdayThisYear =
    today.getMonth() > birth.getMonth() ||
    (today.getMonth() === birth.getMonth() && today.getDate() >= birth.getDate());

  if (!hasHadBirthdayThisYear) {
    age -= 1;
  }

  return `${age}歳`;
}

function formatCareerYears(careerHighlights) {
  const datedHighlights = Array(careerHighlights || [])
    .map((item) => item.date)
    .filter(Boolean)
    .map((date) => new Date(date))
    .filter((date) => !Number.isNaN(date.getTime()))
    .sort((a, b) => a - b);

  if (!datedHighlights.length) {
    return "不明";
  }

  const first = datedHighlights[0];
  const today = new Date();
  let years = today.getFullYear() - first.getFullYear();
  const hasPassedAnniversary =
    today.getMonth() > first.getMonth() ||
    (today.getMonth() === first.getMonth() && today.getDate() >= first.getDate());

  if (!hasPassedAnniversary) {
    years -= 1;
  }

  return `${Math.max(years, 0)}年`;
}

function normalizeName(value) {
  return String(value).replaceAll(/\s+/g, "").replaceAll("　", "");
}

function loadFavorites() {
  try {
    const raw = localStorage.getItem(FAVORITES_KEY);
    const favorites = raw ? JSON.parse(raw) : [];
    return Array.isArray(favorites) ? favorites : [];
  } catch (error) {
    return [];
  }
}

function saveFavorites(favorites) {
  try {
    localStorage.setItem(FAVORITES_KEY, JSON.stringify(favorites));
  } catch (error) {
    setStatus("お気に入り保存に失敗しました。ブラウザ設定をご確認ください。");
  }
}

function renderFooterSpotlight() {
  const candidates = state.events.filter((event) => event.title && event.sourceURL);
  if (!candidates.length) {
    els.footerSpotlightContent.innerHTML = "<p>見どころデータを表示できませんでした。</p>";
    return;
  }

  const event = candidates[Math.floor(Math.random() * candidates.length)];
  const headliner = getFeaturedPerformers(event)[0];
  const performerText = headliner
    ? headliner.displayName
    : Array(event.performers || []).slice(0, 3).join(" / ") || "出演者情報を確認中";

  els.footerSpotlightContent.innerHTML = `
    <p class="footer-spotlight__date">${escapeHtml(formatDate(event.startAt))}</p>
    <h3>${escapeHtml(event.title)}</h3>
    <p class="footer-spotlight__meta">${escapeHtml(event.venueName || "会場未設定")} / ${escapeHtml(event.categoryLabel || "公演")}</p>
    <p class="footer-spotlight__performers">見どころ: ${escapeHtml(performerText)}</p>
    <p class="footer-spotlight__desc">${escapeHtml(event.description || "公開データベースからピックアップした注目公演です。")}</p>
    <a class="link-button link-button--primary" href="${escapeAttribute(event.sourceURL)}" target="_blank" rel="noreferrer">公式ページを見る</a>
  `;
}

function setStatus(message) {
  els.status.textContent = message;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttribute(value) {
  return escapeHtml(value);
}
