# Coolstore review guidelines

## Impact budget

Changes that expand a symbol’s blast-radius impact zone beyond **12 nodes** violate the project’s `policy.json` (`max_impact_nodes`). Prefer small, localized edits in `com.redhat.coolstore.service.*` (for example `ShippingService`) over broad cart/order coupling changes.

## Service layering

- Keep shipping calculation logic inside `ShippingService` / `ShippingServiceRemote`.
- Avoid new call edges from inventory or catalog services into shipping internals without an explicit ADR.
- Cart and order processors may call shipping through the public service API; do not reach into private helpers across packages.

## Demo tip

A deliberate MR that widens `ShippingService` coupling (or lowers `max_impact_nodes` in `policy.json`) should surface as **`new`** / **`regression`** under `rgctl review check` and drive Verdict **RED**. Prose conflicts here without a policy hit stay advisory (YELLOW / Concerns).

## Domain isolation (optional)

`forbidden_crossings` + `node_domains` (node UUIDs from `rgctl find` / blast-radius JSON) can encode hard domain pairs. Leave empty until UUIDs are assigned; do not invent UUIDs in reviews.
