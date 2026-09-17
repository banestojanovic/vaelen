# ADR-0002: Local Routing Provider

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

Vaelen requires a local HTTP/HTTPS routing layer capable of exposing developer projects through predictable local domains such as:

```text
https://project.test
```

The routing layer must support the initial PHP development environment while remaining suitable for future runtimes and application types.

Examples include:

```text
PHP / Laravel / WordPress
Node.js
Go
Python
static sites
arbitrary local HTTP services
```

Vaelen must therefore distinguish between:

1. the **routing capability** required by Vaelen Core; and
2. the software used to implement that capability.

The router must not become part of Vaelen's public architectural identity.

This ADR selects the initial routing provider and defines the abstraction Core depends upon.

---

# Decision

Vaelen will use **Caddy as its initial routing provider**.

Vaelen Core will not depend directly on Caddy-specific concepts.

Instead, Core will interact with a generic `Router` abstraction.

Conceptually:

```text
                   Vaelen Core
                        │
                        ▼
                 Router Protocol
                        │
                        ▼
                  Caddy Router
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
        PHP-FPM       Node/Go       Static
```

Caddy is therefore:

> the first implementation of Vaelen's routing capability.

It is not:

> an architectural requirement that Vaelen must always use Caddy.

---

# 1. Why Vaelen needs a routing provider

A developer should be able to register:

```text
~/Code/my-project
```

and access it through:

```text
https://my-project.test
```

without manually configuring:

* web server configuration;
* ports;
* FastCGI;
* reverse proxies;
* TLS certificates;
* routing files;
* reload commands.

Vaelen Core understands the desired route.

The routing provider implements it.

---

# 2. Why Caddy

Caddy provides several properties particularly suitable for Vaelen.

## Dynamic configuration

Caddy provides a runtime administration API.

This allows Vaelen to modify routing configuration without treating the router as a collection of generated static configuration files requiring manual reload orchestration.

Conceptually:

```text
val link
    │
    ▼
Vaelen Core
    │
    ▼
Router.addRoute(...)
    │
    ▼
Caddy configuration API
    │
    ▼
route active
```

This fits Vaelen's desired-state architecture naturally.

---

## HTTPS

Caddy has strong built-in HTTPS and local certificate capabilities.

Vaelen requires HTTPS to feel like a normal property of a local project rather than an advanced manual configuration task.

The desired user experience is:

```bash
cd ~/Code/project
val link
```

followed by:

```text
https://project.test
```

Caddy already provides much of the underlying TLS machinery necessary to support this model.

Vaelen should orchestrate that capability rather than unnecessarily rebuild a complete local TLS server implementation.

---

## FastCGI

Caddy supports FastCGI and therefore integrates naturally with PHP-FPM.

Conceptually:

```text
project.test
     │
     ▼
   Caddy
     │
     │ FastCGI
     ▼
php-8.4.sock
     │
     ▼
 PHP-FPM
```

This satisfies Vaelen's initial PHP requirements without making the router PHP-specific.

---

## Reverse proxying

Future projects may expose their own HTTP server.

Examples:

```text
Node.js → localhost:3000
Go      → localhost:8080
Python  → localhost:8000
```

Vaelen can expose those consistently:

```text
https://project.test
          │
          ▼
        Caddy
          │
          ▼
   localhost:3000
```

The project-facing experience remains identical regardless of runtime.

---

## Static files

Caddy can also directly serve static sites.

Therefore one routing provider can support:

```text
FastCGI
reverse proxy
static files
```

without Core understanding the implementation differences.

---

# 3. Why not nginx initially

nginx is a highly capable alternative.

It is:

* mature;
* predictable;
* efficient;
* widely understood;
* excellent with PHP-FPM;
* extensively proven in PHP development environments.

Laravel Valet and Herd demonstrate that nginx is entirely suitable for this problem.

nginx is therefore not rejected because of a technical deficiency.

Caddy is selected initially because its runtime configuration model, HTTPS behavior, and general reverse-proxy capabilities align more naturally with Vaelen's dynamic control-center architecture.

Traditional nginx management generally involves a lifecycle resembling:

```text
generate configuration
        │
        ▼
write configuration
        │
        ▼
validate configuration
        │
        ▼
reload nginx
```

This is reliable but places more configuration-generation and reload orchestration responsibility on Vaelen.

Caddy provides a more dynamic control interface.

---

# 4. Caddy is replaceable

No subsystem outside the routing implementation should need to know that Caddy is being used.

Bad:

```text
ProjectManager
    ↓
CaddyManager.addSite(...)
```

Preferred:

```text
ProjectManager
    ↓
Router.addRoute(...)
```

Caddy-specific types must not leak through generic Core APIs.

For example, Core should understand:

```text
Route
RouteTarget
TLSMode
RouteStatus
```

rather than:

```text
Caddyfile
CaddyDirective
CaddyAdapter
CaddyJSON
```

Those belong inside the Caddy provider.

---

# 5. Router contract

Conceptually, the routing provider exposes operations such as:

```swift
protocol Router {
    func start() async throws
    func stop() async throws

    func status() async -> RouterStatus
    func health() async -> HealthStatus

    func reconcile(routes: [Route]) async throws

    func addRoute(_ route: Route) async throws
    func updateRoute(_ route: Route) async throws
    func removeRoute(id: RouteID) async throws
}
```

The exact Swift API may evolve.

The abstraction boundary must remain.

---

# 6. Route model

A route represents Vaelen's desired public-facing mapping.

Conceptually:

```text
Route

identifier
hostname
target
TLS mode
document root where applicable
metadata
```

Example PHP route:

```text
hostname:
    project.test

target:
    FastCGI
    socket: php/8.4.sock

documentRoot:
    /Users/example/Code/project/public

TLS:
    local
```

Example Node route:

```text
hostname:
    frontend.test

target:
    HTTP
    host: 127.0.0.1
    port: 3000

TLS:
    local
```

Example static route:

```text
hostname:
    docs.test

target:
    static

documentRoot:
    /Users/example/Code/docs/dist

TLS:
    local
```

---

# 7. Route target types

Initial architectural target types should include:

```text
FastCGI
HTTP reverse proxy
Static files
```

They represent generic routing concepts.

They do not represent frameworks.

There should not be routing target types such as:

```text
Laravel
WordPress
Symfony
```

Framework-specific project knowledge belongs to Drivers.

For example:

```text
LaravelDriver
      │
      ▼
document root = project/public
      │
      ▼
Route
      │
      ▼
FastCGI target
```

---

# 8. Drivers build routing intent

Drivers may contribute information necessary to construct routes.

Example:

```text
~/Code/shop
      │
      ▼
WordPressDriver
      │
      ├── document root
      ├── front-controller behavior
      └── project metadata
             │
             ▼
           Route
             │
             ▼
           Router
```

The driver must not directly configure Caddy.

This preserves:

```text
Driver → Vaelen model → Router
```

rather than:

```text
Driver → Caddy configuration
```

---

# 9. Router configuration is generated state

Caddy configuration generated by Vaelen is not user-owned project configuration.

The authoritative state is Vaelen's route model.

Conceptually:

```text
Project Registry
      +
Project Config
      +
Runtime Resolution
      │
      ▼
Desired Routes
      │
      ▼
Caddy configuration
```

Therefore Caddy configuration can be regenerated.

Users should not need to manually edit Vaelen's generated Caddy state for normal operation.

---

# 10. Desired-state reconciliation

Routing follows the same desired-state philosophy as the rest of Vaelen.

Core may determine that desired routes are:

```text
a.test
b.test
c.test
```

while the router currently contains:

```text
a.test
b.test
old.test
```

Reconciliation produces:

```text
keep a.test
keep b.test
add c.test
remove old.test
```

The router provider determines the safest way to apply that transition.

Core does not need to know whether that means:

* API calls;
* configuration replacement;
* reload;
* another implementation-specific mechanism.

---

# 11. Configuration updates must be transactional

A malformed new route must not destroy existing working routes.

The provider should apply configuration changes transactionally where supported.

Conceptually:

```text
current healthy config
       │
       ▼
construct new config
       │
       ▼
validate
       │
   ┌───┴────┐
 valid    invalid
   │          │
   ▼          ▼
apply       reject
   │          │
   ▼          ▼
new config  old config remains
```

Routing failure should be isolated as much as practical.

---

# 12. Router ownership

The Caddy process used by Vaelen is owned by Vaelen.

Vaelen must not silently reuse an arbitrary globally installed Caddy instance.

Vaelen manages its own package:

```text
packages/
└── caddy/
    └── <version>/
```

and its own runtime state.

This prevents:

```text
brew upgrade caddy
```

or:

```text
brew uninstall caddy
```

from unexpectedly breaking Vaelen.

External Caddy installations may be detected for conflict diagnostics but are not Vaelen-owned.

---

# 13. Caddy package lifecycle

Caddy should use the same package-management principles as other Vaelen-managed software.

Conceptually:

```text
download
   ↓
verify
   ↓
extract
   ↓
validate
   ↓
install version
   ↓
activate
```

Multiple versions may temporarily coexist during upgrades.

An update should not destroy the known-working version before the replacement has been validated.

---

# 14. Caddy process lifecycle

Caddy is supervised by `vaelend`.

Core tracks:

```text
PID
executable identity
version
start time
admin endpoint/socket
ports
health
resource usage
logs
```

Closing `Vaelen.app` does not stop Caddy.

Exiting a `val` command does not stop Caddy.

Restarting `vaelend` should permit safe reconciliation/adoption where possible.

---

# 15. Administration interface exposure

Caddy's administration interface is an implementation detail.

It must not be exposed more broadly than necessary.

Vaelen should configure the administration interface for local-only access.

Where supported and practical, UNIX-domain communication should be considered over a generally reachable TCP listener.

If TCP localhost is required, exposure should remain strictly local.

Users and external applications should not depend on Caddy's administration API as Vaelen's public API.

They depend on Vaelen Core.

---

# 16. Ports 80 and 443

The preferred user experience is:

```text
http://project.test
https://project.test
```

rather than:

```text
https://project.test:8443
```

Therefore the routing provider should normally serve standard HTTP and HTTPS ports.

However, binding low-numbered ports on macOS introduces privilege and ownership considerations.

Vaelen must not solve this by running its entire routing layer as root without careful justification.

The exact mechanism for safely serving ports 80 and 443 requires implementation validation.

Potential approaches must be evaluated separately.

The architectural requirement is:

> Privilege required for routing must remain narrowly scoped and must not cause unrelated Vaelen services to run as root.

---

# 17. DNS is separate from routing

The router does not own `.test` name resolution.

Conceptually:

```text
project.test
     │
     ▼
macOS resolver
     │
     ▼
127.0.0.1
     │
     ▼
Router
```

DNS is a Vaelen platform capability.

Routing is another platform capability.

They cooperate but remain separate.

This prevents the selected routing provider from becoming responsible for unrelated system configuration.

---

# 18. TLS architecture

TLS has two conceptual layers:

```text
Trust
  │
  └── macOS trusts Vaelen local CA

Issuance
  │
  └── project.test receives certificate
```

Vaelen owns the user experience and trust lifecycle.

Caddy may provide the underlying local certificate issuance machinery.

The architecture must not require Core consumers to know how Caddy internally stores or issues certificates.

---

# 19. Certificate authority ownership

Vaelen should present the local trust relationship as:

```text
Vaelen Local CA
```

rather than exposing internal implementation terminology unnecessarily.

The exact technical ownership of the CA key material must be established during implementation.

Requirements include:

* private key protection;
* predictable backup/removal behavior;
* no unnecessary root access;
* explicit trust installation;
* complete uninstall support.

If Caddy manages underlying CA artifacts, Vaelen must still be capable of identifying and removing the trust it caused to be installed.

---

# 20. HTTPS should be the default

For normal Vaelen-managed web projects:

```text
HTTPS = enabled
```

should be the default.

HTTP may redirect to HTTPS.

Users should be able to explicitly disable HTTPS where necessary.

The default should reflect modern production web development.

---

# 21. Wildcard vs individual certificates

The implementation may evaluate whether Vaelen should use:

* per-host certificates;
* wildcard certificates;
* or provider-managed local issuance.

This ADR does not mandate one approach.

The decision should prioritize:

* security;
* simplicity;
* fast route creation;
* clean trust lifecycle;
* compatibility with browsers and development tooling.

---

# 22. Routing must not require project file mutation

Creating a route must not require modifying the project's source code.

For example:

```bash
val link
```

should not need to alter:

```text
composer.json
package.json
public/index.php
wp-config.php
```

unless a separate explicit integration feature requires it.

Routing infrastructure belongs outside the project.

---

# 23. Hostname generation

Vaelen should provide deterministic local hostnames.

For a linked project named:

```text
my-project
```

the default hostname is:

```text
my-project.test
```

Users may override the hostname.

Hostname generation belongs to project/domain management, not to Caddy.

The router receives the final hostname.

---

# 24. Multiple domains

A project may eventually have multiple local domains.

Example:

```text
shop.test
api.shop.test
admin.shop.test
```

The route model must not assume one project equals exactly one hostname.

Likewise, multiple routes may point to the same runtime.

---

# 25. Wildcard subdomains

Some applications require dynamic subdomains.

Example:

```text
tenant-a.app.test
tenant-b.app.test
*.app.test
```

The architecture should permit wildcard routes.

The exact DNS and certificate implementation may be deferred.

---

# 26. Per-project PHP

The router must support different projects using different PHP runtimes simultaneously.

Example:

```text
legacy.test
    │
    ▼
PHP 8.2 socket

modern.test
    │
    ▼
PHP 8.4 socket
```

Routing therefore resolves a project to a specific runtime endpoint.

It must not assume one global PHP version.

---

# 27. Router does not manage PHP

Caddy must not become responsible for starting or stopping PHP-FPM.

Correct:

```text
Vaelen Core
   │
   ├── Supervisor → PHP-FPM 8.4
   │
   └── Router → route points to PHP socket
```

Incorrect:

```text
Caddy module
   │
   └── starts PHP itself
```

Runtime lifecycle belongs to the runtime module and supervisor.

Routing merely consumes its endpoint.

---

# 28. Router does not manage application servers

Similarly, for Node:

```text
Vaelen Supervisor
      │
      ▼
Node application :3000
      │
      ▼
Router target
```

The router does not become a general-purpose process manager.

---

# 29. Routing failure behavior

If the router process crashes:

* managed application runtimes may continue running;
* databases continue running;
* queues continue running;
* Core reports routing as unavailable;
* affected projects report degraded availability.

Vaelen should not unnecessarily stop unrelated infrastructure because the router failed.

Conceptually:

```text
MySQL       HEALTHY
Redis       HEALTHY
PHP         HEALTHY
Router      FAILED
Project     DEGRADED
```

---

# 30. Runtime failure behavior

If PHP 8.4 fails but the router remains healthy:

```text
legacy.test → PHP 8.2 → HEALTHY
modern.test → PHP 8.4 → FAILED
```

Only routes depending on the failed runtime should become degraded.

The router should remain operational for unrelated projects.

---

# 31. Diagnostics

Router diagnostics are exposed through Core.

Example:

```text
$ val doctor

Routing
✓ Caddy 2.x installed
✓ Caddy running
✓ configuration valid
✓ admin interface responding
✓ port 80 active
✓ port 443 active

Routes
✓ project.test
✓ api.test

TLS
✓ local CA available
✓ local CA trusted
✓ project.test certificate valid
```

Caddy-specific details may appear in advanced diagnostics, but the normal conceptual language should remain Vaelen-oriented.

---

# 32. Logs

Router logs belong to Vaelen's logging system.

Users should be able to run:

```text
val logs router
```

without knowing:

* Caddy's binary path;
* Caddy's log path;
* Caddy's internal configuration location.

Advanced users may still inspect those details.

---

# 33. Router status

Core should expose structured status approximately equivalent to:

```text
provider: caddy
providerVersion: 2.x
state: running
health: healthy
pid: ...
httpPort: 80
httpsPort: 443
routes: 12
memory: ...
uptime: ...
```

Provider information remains useful diagnostically even though clients primarily interact with the generic router concept.

---

# 34. Resource honesty

The router is part of Vaelen's runtime footprint and must therefore be observable.

Vaelen should expose:

* memory;
* CPU;
* PID;
* uptime;
* ports;
* provider version.

If future routing providers are compared, measurements should be based on reproducible benchmarks rather than assumptions.

---

# 35. Benchmarking requirement

Before Caddy becomes a stable long-term dependency, Vaelen should benchmark it against nginx for the project's actual workload.

At minimum:

```text
idle memory
idle CPU
startup time

1 configured site
10 configured sites
100 configured sites

PHP request latency
static request latency

route-add latency
route-remove latency
configuration reconciliation latency

binary size
process count
open file count
```

Tests should be performed on supported Apple Silicon macOS hardware.

The purpose is not to declare a universal winner.

The purpose is to validate that Caddy satisfies Vaelen's performance and resource philosophy.

---

# 36. Conditions for reconsidering Caddy

The routing provider decision should be reconsidered if testing reveals material problems involving:

* idle resource usage;
* route update latency;
* PHP-FPM compatibility;
* certificate behavior;
* privileged port handling;
* stability;
* binary distribution;
* licensing;
* upstream maintenance;
* macOS compatibility.

Because Core depends on `Router`, replacing Caddy should not require redesigning project or module architecture.

---

# 37. Future alternative providers

The architecture should permit a future implementation such as:

```text
Router
   │
   ├── CaddyRouter
   └── NginxRouter
```

This does not mean Vaelen must expose router selection to normal users.

Supporting multiple providers carries maintenance cost.

A second provider should only be implemented when there is a concrete need.

Abstraction exists to preserve architectural independence, not to create unnecessary options.

---

# 38. No premature router plugin system

`Router` is an internal architecture boundary.

Vaelen does not initially need:

```text
val router install nginx
val router install apache
```

or a router marketplace.

The initial product should have one excellent routing implementation.

The abstraction exists so the rest of Vaelen remains clean.

---

# 39. Initial routing scope

The first routing implementation needs to prove:

```text
.test domain
HTTP
trusted HTTPS
PHP-FPM over UNIX socket
static files
route add/remove
multiple PHP versions
route health
```

Reverse proxy support should be architecturally supported and may be implemented early because Caddy provides it naturally.

Advanced features such as:

* wildcard domains;
* custom ports;
* custom headers;
* WebSocket customization;
* complex rewrites;
* advanced proxy policies

should not delay the first usable PHP environment.

---

# 40. Example initial flow

Given:

```text
~/Code/blog
```

containing a Laravel project:

```bash
cd ~/Code/blog
val link
```

Core performs approximately:

```text
Detect project
      │
      ▼
LaravelDriver
      │
      ▼
document root:
~/Code/blog/public
      │
      ▼
resolve PHP runtime
      │
      ▼
PHP 8.4 socket
      │
      ▼
construct Route
      │
      ▼
blog.test
      │
      ▼
Router.reconcile(...)
      │
      ▼
Caddy applies configuration
      │
      ▼
verify route
```

The result:

```text
https://blog.test
```

The developer does not interact directly with Caddy.

---

# 41. Consequences

## Positive

### Dynamic configuration

Routes can be changed through a running routing provider.

### Strong HTTPS foundation

Caddy provides mature automatic/local HTTPS functionality.

### Runtime independence

PHP, Node, Go, static sites, and future runtimes can share the same routing abstraction.

### Less Core complexity

Vaelen delegates mature web-server functionality rather than implementing it.

### Replaceability

Caddy-specific behavior remains isolated.

### Clean project model

Projects describe routes without knowing the underlying web server.

---

# 42. Costs

Caddy introduces:

* another managed upstream binary;
* Go runtime characteristics compiled into the binary;
* provider-specific configuration translation;
* an administration API requiring careful local security;
* local CA behavior that Vaelen must understand sufficiently to uninstall cleanly.

It may also consume more resources than nginx under some workloads.

These costs are accepted provisionally and must be measured.

---

# 43. Alternatives Considered

## nginx

Strong alternative.

Advantages:

* extremely mature;
* very low resource usage;
* proven with PHP-FPM;
* used by Valet/Herd;
* enormous operational knowledge base.

Not selected initially because Vaelen benefits from Caddy's dynamic configuration and integrated HTTPS model.

nginx remains the principal fallback if Caddy proves unsuitable.

---

## Apache

Not selected.

Although mature and widely deployed, it provides no compelling architectural advantage for Vaelen's initial routing requirements compared with Caddy or nginx.

---

## Custom Swift HTTP server

Rejected.

Implementing a production-quality local web server, reverse proxy, FastCGI gateway, and TLS system would violate Vaelen's principle of integrating mature software rather than reinventing it.

---

## Per-project development servers

Rejected as the primary routing architecture.

For example:

```text
Laravel server
Node server
PHP built-in server
```

would create inconsistent URLs, ports, HTTPS behavior, lifecycle management, and routing semantics.

Vaelen requires one coherent front door.

---

# 44. Invariants Established by This ADR

1. Vaelen Core depends on a generic Router abstraction.
2. Caddy is the initial Router implementation.
3. Caddy is not part of Vaelen's public architectural identity.
4. Projects and Drivers must not directly generate Caddy configuration.
5. Router configuration is derived state.
6. DNS and routing remain separate platform capabilities.
7. Runtime lifecycle and routing lifecycle remain separate.
8. The router does not start or supervise application runtimes.
9. Vaelen owns the Caddy package it manages.
10. Global Homebrew Caddy installations are not Vaelen-owned.
11. Routing configuration changes must preserve existing working configuration on failure where practical.
12. HTTPS is the default local-development experience.
13. Caddy's administration API is not Vaelen's public API.
14. The administration interface remains local-only.
15. Router resource usage is observable.
16. Caddy must be benchmarked against nginx before being considered a permanently settled dependency.
17. nginx remains a viable replacement without requiring Core redesign.
18. Vaelen will initially ship one routing provider rather than prematurely creating a user-facing router ecosystem.

---

# Summary

Vaelen requires routing.

Vaelen does not require Caddy specifically.

Core therefore defines a stable routing abstraction and initially implements it using Caddy.

Caddy is selected because its dynamic configuration, automatic HTTPS, FastCGI support, reverse proxy capabilities, and local-development ergonomics align strongly with Vaelen's architecture.

The relationship is:

```text
Vaelen owns the experience.

Router owns the abstraction.

Caddy provides the implementation.
```

If Caddy proves to be the best implementation, it may remain indefinitely.

If it does not, Vaelen should be able to replace it without changing what a project, module, driver, CLI client, or GUI believes routing means.

