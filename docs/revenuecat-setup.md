# RevenueCat 設定メモ

アプリ側のRevenueCat実装は `SilicaApp/Subscriptions` にあります。App Store ConnectとRevenueCat Dashboardの設定が完了して初めて、実際の商品価格・購入が返ります。

## 1. APIキー

`SubscriptionManager.swift` のキーは現在、依頼された次のキーを設定しています。

```text
appl_TvngDOEcicbUtDWbTwTpOFSviKV
```

これはRevenueCatのApple用クライアント公開SDKキーです。クライアントアプリに埋め込めます。Secret API keyやApp Store Connect APIの`.p8`秘密鍵はアプリに入れません。

## 2. RevenueCat Dashboard

1. iOSアプリのBundle IDを `com.fujimakitaketo.silica` にする。
2. Productsに、App Store Connectと同じ商品IDを登録する。
3. Entitlementを次のIDで作る。

   ```text
   Silica Pro
   ```

   大文字・空白を含めてコードと完全一致させる。
4. Entitlement `Silica Pro` に、必要な商品をAttachする。
5. Offeringを作成し、`default` をCurrent Offeringにする。
6. Packagesを追加して商品を割り当てる。推奨構成は次のとおり。

   | Package | App Store | Test Store |
   | --- | --- | --- |
   | Monthly | `silica.pro.monthly` | `silica.pro.monthly` |
   | Annual | `silica.pro.yearly` | `silica.pro.yearly` |
   | Lifetime | `lifetime` | `silica_pro_lifetime` |

   1つのPackageにはアプリごとに商品を1件ずつ割り当てます。実機向けのOfferingには、Test Store商品だけでなくApp Store商品も必ず割り当ててください。
7. Customer Centerを有効化する。アプリの「設定 > Silica Pro > サブスクを管理」から開けます。

このアプリはRevenueCatの既成Paywallではなく、SilicaオリジナルのPaywall UIを使用しています。そのためDashboardのPaywall作成は必須ではありません。商品価格と購入対象を取得するため、Current Offeringは必須です。

## 3. App Store Connectの商品ID

Test Storeでは次のIDを使用しています。

```text
silica.pro.yearly
silica.pro.monthly
silica_pro_lifetime
```

App Store Connect側では、Lifetimeのみ商品IDが `lifetime` です。アプリ側はTest Storeの `silica_pro_lifetime` と、App Store Connect用の `lifetime` の両方に対応しています。

```text
lifetime
silica.pro.yearly
silica.pro.monthly
```

サブスクリプション商品は価格・ローカライゼーション・審査用スクリーンショットなどの必須メタデータを埋め、商品状態が販売可能になるまで待ちます。RevenueCatの価格表示はハードコードせず、StoreKitから返る `localizedPriceString` を表示します。

## 4. アプリ内の導線

- 初回Pro画面: RevenueCat Paywallを表示
- 設定 > Silica Pro: Entitlement状態、プラン価格、購入、購入復元
- サブスクを管理: RevenueCat Customer Center
- 有効判定: `customerInfo.entitlements.active["Silica Pro"] != nil`

Apple Sandboxで試す場合は、App Store ConnectのSandboxテスターでログインした端末から確認します。Simulatorでは実際のApp Store課金確認はできないため、StoreKit Configurationまたは実機Sandboxを使ってください。
