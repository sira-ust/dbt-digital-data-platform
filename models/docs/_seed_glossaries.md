{% docs event_code_glossary %}
Complete event dictionary from API documentation Section 5
(SystemEventLog_API_Documentation_0327, v1.0 March 2026).

Grain: one row per 8-digit `description_code`
(digits 1-2 = L1 Category, 3-4 = L2 Sub-category, 5-6 = L3 Action,
7-8 = L4 Result: 01=Success, 02=Fail, 00=N/A).

`payload_format` legend: none | kv (key:value CSV) | positional_order
(order metadata CSV) | positional (other multi-field CSV) | duration
(`Time:s`) | sku | title | bare_value | fail_marker.

> Auto-generated from `seeds/seed_event_codes.csv` by
> `scripts/generate_event_glossary.py` — do not edit by hand;
> re-run the script when the seed changes.


### L1 = 01 — System Environment (8 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `01010100` | Network: Enable | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |
| `01010200` | Network: Disable | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |
| `01020100` | Battery | bare_value | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |
| `01020200` | Low Battery | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |
| `01030100` | Bluetooth: Enable | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `01030200` | Bluetooth: Disable | none | false | true | System Event | INFO | PDA,CatalogFS |
| `01040100` | Location-Success | none | true | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `01040200` | Location-Fail | fail_marker | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |


### L1 = 02 — Login & Logout (11 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `02010100` | Sales Equipment Permission - Success | bare_value | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `02010200` | Sales Equipment Permission - Fail | none | false | true | System Event | WARN | PDA,CatalogFS,CatalogSE |
| `02020100` | Sending Local Log - Successful | none | false | true | System Event | INFO | PDA |
| `02020200` | Sending Local Log - Failed | none | false | true | System Event | WARN | PDA |
| `02030101` | Login: Username - Success | none | true | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE,Web |
| `02030102` | Login: Username - Fail | none | true | true | System Event | WARN | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE,Web |
| `02030201` | Login: SSO - Success | none | true | true | System Event | INFO | PDA,CatalogFS |
| `02030202` | Login: SSO - Fail | none | true | true | System Event | WARN | PDA,CatalogFS |
| `02040000` | Logout | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE,Web |
| `02040100` | Timeout | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |
| `02040200` | Voluntarily Exit | none | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC,CatalogSE |


### L1 = 03 — Data Download & Sync (22 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `03010100` | Auto Download - Success | duration | false | true | System Event | INFO | PDA |
| `03010200` | Auto Download - Fail | fail_marker | false | true | System Event | WARN | PDA |
| `03020100` | Settings > FD - Success | duration | false | true | System Event | INFO | PDA,CatalogFS,CatalogFC,CatalogSE |
| `03020200` | Settings > FD - Fail | fail_marker | false | true | System Event | WARN | PDA,CatalogFS,CatalogFC,CatalogSE |
| `03030100` | Full Download Popup - Success | duration | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03030200` | Full Download Popup - Fail | fail_marker | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03040100` | Sync Popup - Success | duration | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03040200` | Sync Popup - Fail | fail_marker | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03040300` | Sync Popup - Skip | none | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03050100` | Full Download (Auto) - Success | duration | false | true | System Event | INFO | Vegas,CatalogFC |
| `03050200` | Full Download (Auto) - Fail | fail_marker | false | true | System Event | WARN | Vegas,CatalogFC |
| `03060100` | Background Update - Success | duration | false | true | System Event | INFO | Vegas,CatalogFC |
| `03060200` | Background Update - Fail | fail_marker | false | true | System Event | WARN | Vegas,CatalogFC |
| `03070100` | Left Menu: Sync Catalog - Success | duration | false | true | System Event | INFO | CatalogFS,CatalogFC,CatalogSE |
| `03070200` | Left Menu: Sync Catalog - Fail | fail_marker | false | true | System Event | WARN | CatalogFS,CatalogFC,CatalogSE |
| `03080100` | Customer List Sync - Success | duration | false | true | System Event | INFO | CatalogFS,CatalogSE |
| `03080200` | Customer List Sync - Fail | fail_marker | false | true | System Event | WARN | CatalogFS,CatalogSE |
| `03090100` | Show FD Skip - Login | kv | false | true | System Event | INFO | CatalogFS,CatalogSE |
| `03090200` | Show FD Skip - Home | kv | false | true | System Event | INFO | PDA,CatalogFS,CatalogSE |
| `03090300` | Show FD Skip - Customer List | kv | false | true | System Event | INFO | CatalogFS |
| `03100100` | Home Download - Success | duration | false | true | System Event | INFO | PDA |
| `03100200` | Home Download - Fail | fail_marker | false | true | System Event | WARN | PDA |


### L1 = 04 — Send Order (10 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `04010100` | Order List: Customer - Success | positional_order | true | true | System Event | INFO | PDA,CatalogFS |
| `04010200` | Order List: Customer - Fail | positional_order | true | true | System Event | WARN | PDA,CatalogFS |
| `04020100` | Order List: Sales - Success | positional_order | true | true | System Event | INFO | PDA,CatalogFS |
| `04020200` | Order List: Sales - Fail | none | true | true | System Event | WARN | PDA,CatalogFS |
| `04030100` | Order Detail: Customer - Success | positional_order | true | true | System Event | INFO | PDA,CatalogFS |
| `04030200` | Order Detail: Customer - Fail | none | true | true | System Event | WARN | PDA,CatalogFS |
| `04040100` | Order Detail: Sales - Success | positional_order | true | true | System Event | INFO | PDA,CatalogFS |
| `04040200` | Order Detail: Sales - Fail | none | true | true | System Event | WARN | PDA,CatalogFS |
| `04050100` | submit_quote_cart_page - Success | bare_value | true | true | System Event | INFO | Vegas,CatalogFC,CatalogSE |
| `04050200` | submit_quote_cart_page - Fail | bare_value | true | true | System Event | WARN | Vegas,CatalogFC,CatalogSE |


### L1 = 05 — Request Review (4 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `05010100` | Request Review: Order List - Success | positional_order | false | true | System Event | INFO | PDA,CatalogFS |
| `05010200` | Request Review: Order List - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |
| `05020100` | Request Review: Order Detail - Success | positional_order | false | true | System Event | INFO | PDA,CatalogFS |
| `05020200` | Request Review: Order Detail - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |


### L1 = 06 — Send Sales Review (6 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `06010100` | Sales Review: Order Detail - Success | bare_value | false | true | System Event | INFO | PDA,CatalogFS |
| `06010200` | Sales Review: Order Detail - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |
| `06020100` | Sales Review: Order List - Success | positional_order | false | true | System Event | INFO | PDA,CatalogFS |
| `06020200` | Sales Review: Order List - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |
| `06030100` | Sales Review: Auto Upload - Success | positional_order | false | true | System Event | INFO | PDA,CatalogFS |
| `06030200` | Sales Review: Auto Upload - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |


### L1 = 07 — Restore Order (4 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `07010100` | Restore: Order Detail - Success | bare_value | false | true | System Event | INFO | PDA,CatalogFS |
| `07010200` | Restore: Order Detail - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |
| `07020100` | Restore: Recycle Bin - Success | bare_value | false | true | System Event | INFO | PDA,CatalogFS |
| `07020200` | Restore: Recycle Bin - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS |


### L1 = 08 — Delete Order (3 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `08010000` | Delete: Order Detail | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `08020000` | Delete: Sales Order List | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `08030000` | Auto Delete Order | bare_value | false | false | — | INFO | PDA,CatalogFS |


### L1 = 09 — Create Order (8 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `09010000` | Create Order | bare_value | true | false | — | INFO | PDA,CatalogFS |
| `09020000` | Copy to New Order: Sales List | none | true | false | — | INFO | PDA |
| `09030000` | Copy to New Order: Office List | none | true | false | — | INFO | PDA |
| `09040000` | Copy to New Order: Recycle Bin | none | true | false | — | INFO | PDA |
| `09050000` | (BLE Only) Create New Order | none | true | false | — | INFO | PDA |
| `09060000` | (BLE Only) Use Existing Order on Catalog | none | true | false | — | INFO | PDA |
| `09070000` | (BLE Only) Merge Orders | none | true | false | — | INFO | PDA |
| `09080000` | Item Long Press +: Create New Order | none | true | false | — | INFO | CatalogFS |


### L1 = 10 — Order Operations (27 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `10010100` | Change Shipping Address | positional | false | false | — | INFO | PDA |
| `10010300` | Change Address: Order Detail | none | false | false | — | INFO | CatalogFS |
| `10010400` | Change Address: Place Your Order | none | false | false | — | INFO | Vegas |
| `10020100` | Change Freight | none | false | false | — | INFO | PDA |
| `10040100` | Delete Item: Order Detail | sku | false | false | EVENT | EVENT | CatalogFS |
| `10040700` | remove_item_suggest_page | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10040800` | remove_item_promo_page | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10040900` | remove_item_new_page | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10041000` | remove_item_backorder_page | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10041100` | remove_item_category_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10041300` | remove_item_history_page | sku | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10041400` | remove_item_cart_page | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050100` | add_item_list_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050200` | add_item_suggest_page | positional | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10050300` | add_item_promo_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050400` | add_item_backorder_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050500` | add_item_new_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050600` | add_item_history_page | positional | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10050700` | add_item_detail_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10050800` | add_item_quick_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,Web |
| `10051400` | add_item_category_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10150100` | change_qty_item_list_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10150200` | change_qty_item_suggest_page | positional | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10150300` | change_qty_item_promo_page | positional | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10150500` | change_qty_item_new_page | positional | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `10150700` | change_qty_item_detail_page | positional | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `10160100` | change_price_for_sales | positional | false | false | EVENT | EVENT | PDA,CatalogFS |


### L1 = 11 — Filtering & Sorting (14 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `11010100` | Filter By Category: New & Promo | bare_value | false | false | — | INFO | PDA |
| `11010200` | Filter By Category: Recommend | bare_value | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `11010500` | Filter By Category: Catalog | bare_value | false | false | — | INFO | CatalogFS,CatalogFC |
| `11020100` | Filter By Country: New & Promo | bare_value | false | false | — | INFO | PDA |
| `11020200` | Filter By Country: Recommend | bare_value | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `11050100` | Filter By Status: Order List Customer | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `11050200` | Filter By Status: Order List Sales | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `11050400` | Filter By Status: Order List (Vegas/FC) | bare_value | false | false | — | INFO | Vegas,CatalogFC |
| `11060100` | Filter By Customer: Order List Customer | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `11070100` | Filter By Date: Order List Customer | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `11090300` | Reset Filter: Recommend | none | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `11120100` | Sort: Order List Customer | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `11121300` | Sort: Recommended | bare_value | false | false | — | INFO | CatalogFS,Vegas,CatalogFC |
| `11121500` | Sort: Cart | bare_value | false | false | — | INFO | Vegas |


### L1 = 12 — Search (8 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `12010100` | Search: Order List Customer | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `12010200` | Search: Order List Sales | bare_value | false | false | — | INFO | PDA,CatalogFS |
| `12010800` | Search: Recommend | bare_value | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `12011100` | Search: Order Detail | bare_value | false | false | — | INFO | CatalogFS,CatalogFC |
| `12011200` | Search: Home Bar | bare_value | false | false | — | INFO | CatalogFS,Vegas,CatalogFC,Web |
| `12011300` | Search: Search Page | bare_value | false | false | — | INFO | Vegas |
| `12011600` | Search: Back Order | bare_value | false | false | — | INFO | Vegas |
| `12011700` | Search: Cart | bare_value | false | false | — | INFO | Vegas |


### L1 = 13 — Send Email / Fax (4 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `13010100` | Invoice - Success | bare_value | false | true | System Event | INFO | PDA,Vegas |
| `13010200` | Invoice - Fail | bare_value | false | true | System Event | WARN | PDA,Vegas |
| `13020100` | Statement/Balance - Success | bare_value | false | true | System Event | INFO | PDA,CatalogFS,Vegas,CatalogFC |
| `13020200` | Statement/Balance - Fail | bare_value | false | true | System Event | WARN | PDA,CatalogFS,Vegas,CatalogFC |


### L1 = 14 — Item Detail Navigation (11 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `14010000` | Item Detail: New & Promo | sku | false | false | EVENT | EVENT | PDA,Web |
| `14020000` | Item Detail: Recommend | sku | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `14030000` | Item Detail: Purchase History | sku | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `14040000` | Item Detail: Review | sku | false | false | EVENT | EVENT | PDA |
| `14050000` | Item Detail: Line Item | sku | false | false | EVENT | EVENT | PDA |
| `14080000` | Item Detail: Order Detail | sku | false | false | EVENT | EVENT | CatalogFS,CatalogFC |
| `14090000` | Item Detail: My Lists | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `14100000` | Item Detail: Back Order | sku | false | false | EVENT | EVENT | Vegas,Web |
| `14110000` | Item Detail: Cart | sku | false | false | EVENT | EVENT | Vegas,Web |
| `14140000` | Item Detail: Catalog | sku | false | false | EVENT | EVENT | CatalogFS,CatalogFC |
| `14150000` | Item Detail: Recommend by Service | sku | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |


### L1 = 15 — Item Image Enlarge (2 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `15010000` | Item Enlarge: Product Detail | sku | false | false | — | INFO | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `15020000` | Item Enlarge: Catalog | sku | false | false | — | INFO | CatalogFS,CatalogFC |


### L1 = 16 — Settings & Account (13 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `16010000` | Settings: Location | none | false | false | — | INFO | PDA |
| `16030000` | Settings: Address Confirmation ON | none | false | false | — | INFO | PDA |
| `16040000` | Settings: Address Confirmation OFF | none | false | false | — | INFO | PDA |
| `16050000` | Settings: On-Screen Keyboard ON | none | false | false | — | INFO | PDA |
| `16060000` | Settings: On-Screen Keyboard OFF | none | false | false | — | INFO | PDA |
| `16100000` | Check APP Version | none | false | false | — | INFO | PDA,CatalogFS,CatalogFC |
| `16110000` | Settings: BLE Settings | none | false | false | — | INFO | PDA |
| `16120100` | Setting: Face ID ON | none | false | false | — | — | CatalogFS |
| `16120200` | Setting: Face ID OFF | none | false | false | — | — | CatalogFS |
| `16130000` | Setting: Manage Categories | none | false | false | — | — | CatalogFS |
| `16140100` | Setting: Show Price ON | none | false | false | — | — | CatalogFS |
| `16140200` | Setting: Show Price OFF | none | false | false | — | — | CatalogFS |
| `16150100` | Setting: Only Show In Stock ON | none | false | false | — | — | CatalogFS |


### L1 = 17 — BLE (39 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `17010100` | BLE: Home ON | none | false | false | — | INFO | PDA |
| `17010200` | BLE: Home OFF | none | false | false | — | INFO | PDA |
| `17010300` | BLE: Menu ON | none | false | false | — | INFO | PDA |
| `17010400` | BLE: Menu OFF | none | false | false | — | INFO | PDA |
| `17010500` | BLE: Setting ON | none | false | false | — | INFO | PDA |
| `17010600` | BLE: Setting OFF | none | false | false | — | INFO | PDA |
| `17010700` | BLE MODE Timeout | none | false | false | — | INFO | PDA |
| `17020101` | BLE: Pair - Success | none | false | false | — | INFO | PDA |
| `17020102` | BLE: Pair - Fail | none | false | false | — | INFO | PDA |
| `17020200` | BLE: Unpair | none | false | false | — | INFO | PDA |
| `17020301` | BLE: Auto Connection - Success | none | false | false | — | INFO | PDA |
| `17020302` | BLE: Auto Connection - Fail | none | false | false | — | INFO | PDA |
| `17030000` | BLE: Forget Device | none | false | false | — | INFO | PDA |
| `17040101` | BLE Scan: Home - Found | none | false | false | — | INFO | PDA |
| `17040102` | BLE Scan: Home - Not Found | none | false | false | — | WARN | PDA |
| `17040201` | BLE Scan: Setting - Found | none | false | false | — | INFO | PDA |
| `17040202` | BLE Scan: Setting - Not Found | none | false | false | — | WARN | PDA |
| `17040301` | BLE Scan: BLE Link ON - Found | none | false | false | — | INFO | PDA |
| `17040302` | BLE Scan: BLE Link ON - Not Found | none | false | false | — | WARN | PDA |
| `17040401` | BLE Scan: Menu - Found | none | false | false | — | INFO | PDA |
| `17040402` | BLE Scan: Menu - Not Found | none | false | false | — | WARN | PDA |
| `17040501` | BLE Auto Scan - Found | none | false | false | — | INFO | PDA |
| `17040502` | BLE Auto Scan - Not Found | none | false | false | — | WARN | PDA |
| `17050101` | BLE Op: Lock/Unlock Catalog | bare_value | false | false | — | INFO | PDA |
| `17050201` | BLE Op: Jump to Back | none | false | false | — | INFO | PDA |
| `17050301` | BLE Op: Jump to Categories | positional | false | false | — | INFO | PDA |
| `17050401` | BLE Op: Jump to Backorder | none | false | false | — | INFO | PDA |
| `17050501` | BLE Op: Jump to Purchase History | none | false | false | — | INFO | PDA |
| `17050601` | BLE Op: Jump to Recommend | none | false | false | — | INFO | PDA |
| `17050701` | BLE Op: Jump to Cart | none | false | false | — | INFO | PDA |
| `17050801` | BLE Op: Jump to Item Family | sku | false | false | — | INFO | PDA |
| `17050901` | BLE Op: Catalog Left Slide | none | false | false | — | INFO | PDA |
| `17051001` | BLE Op: Catalog Right Slide | none | false | false | — | INFO | PDA |
| `17051101` | BLE Op: Jump to Search Results | bare_value | false | false | — | INFO | PDA |
| `17051301` | BLE Op: Item Highlight - Line Item | sku | false | false | — | INFO | PDA |
| `17051302` | BLE Op: Item Highlight - New & Promo | sku | false | false | — | INFO | PDA |
| `17051303` | BLE Op: Item Highlight - Recommend | sku | false | false | — | INFO | PDA |
| `17051401` | BLE Op: Jump to Detail - Product Detail | sku | false | false | — | INFO | PDA |
| `17051402` | BLE Op: Jump to Detail - Hard Keys | sku | false | false | — | INFO | PDA |


### L1 = 18 — Activity (Customer Interactions) (12 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `18010000` | Scan Barcode | kv | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC |
| `18020000` | click_backorder_icon | title | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `18030000` | click_history_icon | title | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `18040000` | click_suggest_icon | title | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `18050000` | click_new_icon | title | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `18060000` | click_promo_icon | title | false | false | EVENT | EVENT | PDA,CatalogFS,Vegas,CatalogFC,Web |
| `18070000` | click_new&promo_icon | title | false | false | EVENT | EVENT | PDA,Vegas,CatalogFC,Web |
| `18080000` | click_all_product_icon | title | false | false | EVENT | EVENT | PDA,Vegas,CatalogFC,Web |
| `18090000` | click_categories_icon | bare_value | false | false | EVENT | EVENT | CatalogFS,Vegas,CatalogFC,Web |
| `18100000` | promo_to_buttom | none | false | false | EVENT | EVENT | Vegas,Web |
| `18110000` | new_to_buttom | none | false | false | EVENT | EVENT | Vegas,Web |
| `18120000` | rec_to_buttom | none | false | false | EVENT | EVENT | Vegas |


### L1 = 19 — Catalog View Analytics (1 events)

| Code | Function | Payload | Geo | System | Type | Level | Platforms |
|---|---|---|---|---|---|---|---|
| `19010000` | Catalog View | kv | true | false | EVENT | EVENT | CatalogFS,CatalogFC |

{% enddocs %}
{% docs app_sources_glossary %}
All 9 app source codes from API documentation Section 2.3.
Naming convention: App Name - Platform (I=iOS, A=Android);
single-platform apps omit the suffix.

> Auto-generated from `seeds/seed_app_sources.csv` by
> `scripts/generate_event_glossary.py` — do not edit by hand;
> re-run the script when the seed changes.


| Source code | App | Full name | User type | Platform |
|---|---|---|---|---|
| `CatalogFC-A` | CatalogFC | Catalog For Customer (Android) | Customer | Android |
| `CatalogFC-I` | CatalogFC | Catalog For Customer (iOS) | Customer | iOS |
| `CatalogFS-A` | CatalogFS | Catalog For Sales (Android) | Sales | Android |
| `CatalogFS-I` | CatalogFS | Catalog For Sales (iOS) | Sales | iOS |
| `CatalogSE` | CatalogSE | K.M.Trading Special Edition | Customer | iOS |
| `PDA-A` | PDA | PDA — Handheld Sales Device | Sales | Android |
| `Vegas-A` | Vegas | Vegas — Customer App (Android) | Customer | Android |
| `Vegas-I` | Vegas | Vegas — Customer App (iOS) | Customer | iOS |
| `Web` | Web | Website (Latest Version) | Customer | Web |
{% enddocs %}
{% docs categories_glossary %}
Complete catalog category id -> name map from API documentation §8.4
(18 categories). 4-digit repeated ids (1111, 4444, ...) are virtual
app sections, not real product categories.

> Auto-generated from `seeds/seed_categories.csv` by
> `scripts/generate_event_glossary.py` — do not edit by hand;
> re-run the script when the seed changes.


### Product categories

| Id | Name |
|---|---|
| `6` | Rice & Noodles |
| `19` | Canned Goods & Vegetables |
| `20` | Seafood & Meat |
| `21` | Baking & Mixes |
| `24` | Desserts & Sweets |
| `25` | Snacks |
| `26` | Beverages |
| `27` | Fresh & Frozen |
| `28` | Household |
| `43` | Sauces & Seasonings |
| `134` | Special Items |
| `168` | Scraping music |

### Virtual sections

| Id | Name |
|---|---|
| `1111` | New |
| `4444` | Back Order |
| `5555` | Purchase History |
| `7777` | HOT |
| `8888` | Promo |
| `9999` | Recommend |
{% enddocs %}
