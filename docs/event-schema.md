# イベントデータの持ち方

落語公演を複数ソースから集約するための、共通イベントモデルです。

## 基本モデル

```json
{
  "id": "source:rakugo-kyokai:event:abc123",
  "title": "柳家三三独演会",
  "category": "dokuenkai",
  "subCategory": "rakugokai",
  "startAt": "2026-05-31T19:00:00+09:00",
  "endAt": null,
  "doorOpenAt": "2026-05-31T18:30:00+09:00",
  "allDay": false,
  "venueName": "深川江戸資料館",
  "venueAddress": "江東区白河1-3-28",
  "prefecture": "東京都",
  "city": "江東区",
  "performers": [
    "柳家三三"
  ],
  "description": "個人利用の集約用に整形した公演概要",
  "priceText": "前売 3800円 / 当日 3800円",
  "ticketURL": "https://example.com/ticket",
  "sourceName": "落語協会",
  "sourceURL": "https://www.rakugo-kyokai.jp/rakugokai/ss42ip43ct",
  "lastConfirmedAt": "2026-04-22T09:00:00+09:00",
  "fetchedAt": "2026-04-22T09:00:00+09:00"
}
```

## `category` の候補

- `yose`
- `hall`
- `dokuenkai`
- `rakugokai`
- `special`

## 重複判定の考え方

以下が近いものは同一イベント候補として扱います。

- 公演名
- 開催日
- 開演時刻
- 会場名

完全一致だけでは足りないので、正規化キーも持つとよいです。

### 例

- `normalizedTitle`
- `normalizedVenueName`
- `normalizedPerformerNames`

## ソースごとに保持したい補助情報

```json
{
  "sourceMeta": {
    "site": "rakugo-kyokai",
    "pageType": "rakugokai_detail",
    "rawDateText": "2026年05月31日",
    "rawOpenText": "18:30",
    "rawStartText": "19:00"
  }
}
```

これを残しておくと、パーサー修正時の再検証がかなり楽になります。

## UI 用の補助フィールド

- `isFavorite`
- `isToday`
- `isThisWeekend`
- `distanceLabel`
- `calendarExportURL`

`isFavorite` のようなユーザー状態は、サーバー共通データと分離して持つのが安全です。

## MVP で後回しにしてよいもの

- 座席種別の厳密管理
- 複数チケット販売 URL の管理
- 出演者プロフィール連携
- 地図経路の事前計算

## 先に決めておくと楽なルール

1. `昼の部` と `夜の部` は別イベントとして扱う
2. 日時不明のイベントは保存しても一覧には出さない
3. `sourceURL` は必須
4. チケット URL がなくてもイベントは採用する
