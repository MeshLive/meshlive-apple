# DSA and availability (App Store Connect)

## EU Digital Services Act trader status

The owner decides. Recommendation: declare **not a trader** if the app stays free, open source and non-commercial and the
owner earns nothing from it. The alternative, **trader**, requires a public name, address, phone and email shown on EU
storefronts, and Apple may remove the app from the EU if the details are missing.

Facts for the owner: free, no in-app purchases, no ads, GNU GPL, an individual developer account. This is not legal
advice.

## Availability and pricing

| Question | Answer | Reason |
|---|---|---|
| Territories | All territories except mainland China | An ICP filing is required in mainland China. |
| Price | Free | A free app cannot later become paid under the same listing. |
| Release | Manual release after approval | The owner chooses when the approved version goes live. |
| Phased release | Not applicable | This is a first version. |
| Pre-order | No | The app is submitted when it is ready. |
| Apple Silicon Mac and Apple Vision availability of the iPhone app | Off | The native Mac version ships under the same record later; the iPhone app is not offered as a designed-for-iPad or Vision app. |
| Categories | Primary: Social Networking; secondary: Utilities | See `categories.txt`. |
| EULA | Apple's standard licence agreement, with the Terms of use link in the description | A custom EULA would sit on top of the GNU GPL; the owner chooses. |
| App Review contact | The owner's name, phone and email, entered in App Store Connect only | Never put these in a repository file. |
| Sign-in required | No | There are no accounts. |

**Verify in the form:** the pricing, availability and business sections change between App Store Connect revisions; the
intent is free, all territories except mainland China, manual release, and the owner's trader decision.
