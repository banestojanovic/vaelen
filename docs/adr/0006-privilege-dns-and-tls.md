ADR-0006: Privilege, DNS, and Local TLS
	•	Status: Proposed
	•	Date: 2026-09-17
	•	Decision owners: Vaelen maintainers
Context
Vaelen should provide a local development experience such as:
https://project.test
without requiring developers to manually:
	•	edit /etc/hosts;
	•	configure DNS;
	•	generate certificates;
	•	trust certificates;
	•	configure a web server;
	•	repeatedly enter administrator credentials.
Most Vaelen functionality does not require root privileges.
PHP, MySQL, Redis, Mailpit, project processes, package management, logs, configuration, and Core state should all operate as the logged-in user.
A small number of macOS integrations may require elevated privileges.
Potential examples include:
	•	installing .test resolver configuration;
	•	modifying certificate trust;
	•	installing or updating a privileged helper;
	•	enabling routing behavior required for ports 80 and 443.
Vaelen must solve these requirements without turning vaelend into a root daemon.
The guiding rule is:
Privilege is a capability, not a runtime mode.

Decision
Vaelen will run its normal runtime entirely as the logged-in user.
A separate privileged helper will exist only for narrowly defined system operations that genuinely require elevation.
The architecture is:
Vaelen.app
     │
     ▼
  vaelend
   user
     │
     │ authenticated XPC
     ▼
VaelenPrivilegedHelper
     root
     │
     ├── DNS resolver installation
     ├── local CA trust operations
     └── explicitly approved system operations
The privileged helper:
	•	does not supervise developer services;
	•	does not download packages;
	•	does not execute arbitrary shell commands;
	•	does not interpret module manifests;
	•	does not manage projects;
	•	does not become a general-purpose root API.

1. Default execution identity
The following run as the logged-in user:
Vaelen.app
vaelend
Caddy
PHP-FPM
MySQL
PostgreSQL
Redis
Mailpit
Meilisearch
queue workers
scheduler processes
project servers
This is the default unless a future ADR proves a specific exception necessary.

2. Why Core must not run as root
Running vaelend as root would give every Core feature unnecessary system authority.
A bug in:
module installation
project path handling
archive extraction
process execution
configuration rendering
would then operate with root privileges.
That is incompatible with Vaelen's security philosophy.
It would also risk producing root-owned files inside user development environments.
Therefore:
vaelend == user process
is an architectural invariant.

3. Privileged helper
Vaelen may install a dedicated helper with elevated authority.
Conceptually:
VaelenPrivilegedHelper
The exact executable/bundle identifier will be selected during implementation.
Its interface is deliberately small.
Potential operations include:
installResolver(...)
removeResolver(...)

installTrustedCA(...)
removeTrustedCA(...)

performApprovedRoutingSetup(...)
removeApprovedRoutingSetup(...)
Each method corresponds to a known system capability.

4. No arbitrary privileged execution
The helper must never expose:
func executeAsRoot(command: String)
or:
func run(executable: String, arguments: [String])
for arbitrary caller-controlled executables.
That would effectively make:
vaelend → root shell
and destroy the privilege boundary.

5. Privileged requests describe intent
Correct:
Install resolver for:
.test → 127.0.0.1
Incorrect:
Write these arbitrary bytes to:
some arbitrary root-owned path
The helper understands a small set of Vaelen system operations and validates them independently.

6. Defense in depth
vaelend validating a privileged request is not sufficient.
The helper validates again.
For example:
vaelend
   │
   │ installResolver("test")
   ▼
helper
   │
   ├── validate allowed domain
   ├── validate expected target
   ├── validate destination
   └── perform controlled write
A compromised or buggy Core should not automatically gain arbitrary root filesystem access.

7. XPC boundary
Communication between:
vaelend
and:
VaelenPrivilegedHelper
uses authenticated XPC as established by ADR-0005.
The helper should validate the identity/signing requirements of its client using supported macOS security mechanisms.
The exact implementation depends on the deployment mechanism selected during development.

8. Helper lifecycle
The privileged helper should not perform periodic work merely because it is installed.
Its purpose is privileged operations, not continuous monitoring.
Conceptually:
installed
   │
   ├── no privileged operation
   │        ↓
   │     no work
   │
   └── request arrives
            ↓
       perform operation
Whether macOS keeps the helper process resident is an implementation detail.
Vaelen itself must not require a busy root daemon.

9. Installation authorization
Installing the privileged helper may require explicit macOS authorization.
That is acceptable.
The desired experience is:
First system setup
      │
      ▼
macOS authorization
      │
      ▼
helper installed
rather than prompting for administrator credentials on every:
val link
The exact authorization flow must follow current supported macOS mechanisms.

10. No password handling
Vaelen must never:
	•	ask users to type an administrator password into a Vaelen text field;
	•	store administrator passwords;
	•	pass passwords through IPC;
	•	automate sudo password entry.
macOS owns authorization UI and credential handling.

11. DNS requirement
Vaelen requires predictable local development name resolution.
Default development TLD:
.test
Example:
project.test
api.test
shop.test
must resolve locally.

12. Why .test
.test is specifically reserved for testing use and is suitable for private local development names.
Vaelen should therefore default to:
.test
rather than inventing a TLD that could conflict with public DNS.

13. DNS architecture
DNS and HTTP routing are separate concerns.
Conceptually:
Browser
   │
   ▼
project.test
   │
   ▼
macOS resolver
   │
   ▼
127.0.0.1
   │
   ▼
Vaelen Router
   │
   ▼
project runtime
Caddy does not own the .test resolver.
The PHP module does not own it.
The Project Driver does not own it.
DNS is a Vaelen platform capability.

14. Resolver-based DNS
The preferred macOS integration is resolver configuration under:
/etc/resolver/
Conceptually:
/etc/resolver/test
This allows macOS to route queries for .test through Vaelen's selected local DNS mechanism.
The exact resolver contents depend on the DNS implementation.

15. No per-project /etc/hosts
Vaelen should not implement project registration by repeatedly modifying:
/etc/hosts
for every project.
Bad:
127.0.0.1 project-a.test
127.0.0.1 project-b.test
127.0.0.1 project-c.test
This creates:
	•	repeated privileged writes;
	•	stale entries;
	•	wildcard limitations;
	•	ownership ambiguity;
	•	poor dynamic behavior.
Vaelen should establish .test resolution once and then manage projects in user space.

16. DNS provider abstraction
As with routing, Core should not spread implementation-specific DNS assumptions everywhere.
Conceptually:
DNSProvider
├── start()
├── stop()
├── status()
├── health()
└── resolveDomain(...)
The exact implementation may initially use a lightweight DNS service or another proven approach.
The rest of Core should care primarily that:
*.test
resolves to the Vaelen local environment.

17. DNS service runs as user where possible
If Vaelen runs a local DNS responder, that service should run as the logged-in user whenever technically feasible.
Only the minimal macOS system configuration required to route .test queries to it belongs behind the privileged boundary.
Conceptually:
User space:
    local DNS responder

Root operation:
    tell macOS where .test queries go
not:
root daemon:
    entire DNS implementation

18. DNS port constraints
Traditional DNS commonly uses port 53.
Binding or integrating with port 53 may introduce privilege and conflict considerations.
Vaelen should evaluate whether macOS resolver configuration can direct .test queries to a user-owned resolver on a non-privileged local port.
The exact port strategy must be validated through a prototype.
The architectural goal is:
Keep the DNS responder unprivileged if macOS allows a reliable implementation.

19. DNS conflicts
Vaelen must detect conflicts with existing local development systems.
Potential examples include:
Laravel Herd
Laravel Valet
dnsmasq
other local DNS responders
VPN/security software
If .test is already configured, Vaelen should inspect before modifying.
It must not blindly overwrite working user configuration.

20. Resolver ownership
Before creating:
/etc/resolver/test
Vaelen checks whether it exists.
Possible states:
absent
Vaelen-owned
compatible external
conflicting external
unknown
Only the first two permit straightforward automated management.
External configuration requires conservative behavior.

21. Existing compatible resolver
If an existing resolver already provides compatible .test behavior, Vaelen may be able to coexist with it.
However, Vaelen must not record:
I created this resolver
when it did not.
Ownership and compatibility are separate facts.

22. System modification ledger
ADR-0004 established that Vaelen tracks external system modifications.
DNS setup records:
capability:
    test-resolver

ownership:
    created-by-vaelen

previous-state:
    absent

installed-state:
    ...
If Vaelen modifies pre-existing compatible state in a future design, the previous state must be preserved sufficiently for safe restoration.

23. DNS uninstall
During Vaelen system uninstall:
Vaelen-created resolver
       ↓
safe to remove
but:
external resolver merely detected
       ↓
must remain
Uninstall must never reduce ownership reasoning to:
if file exists:
    delete

24. DNS health
Core should be able to verify DNS independently from routing.
Example:
Resolve:
vaelen-diagnostic.test

Expected:
127.0.0.1
This allows val doctor to distinguish:
DNS broken
from:
router broken

25. Local TLS requirement
Vaelen-managed web projects should use HTTPS by default.
Example:
https://project.test
should work without browser certificate warnings after initial Vaelen system setup.

26. TLS layers
Local HTTPS contains two separate concerns:
Trust
   │
   └── macOS/browser trusts local CA

Issuance
   │
   └── certificate exists for project.test
These must remain conceptually separate.

27. Local certificate authority
Vaelen will provide or orchestrate a local certificate authority used exclusively for local development.
Conceptually presented to the user as:
Vaelen Local CA
The implementation may leverage Caddy's local PKI capabilities where appropriate.
However, Vaelen owns the lifecycle from the user's perspective.

28. Caddy does not own Vaelen's security architecture
Caddy may implement certificate issuance.
That does not mean Core should become coupled to:
Caddy-specific certificate paths
Caddy-specific trust commands
Caddy-specific PKI terminology
The architecture remains:
TLS Provider
      │
      ▼
Caddy-backed implementation
where practical.

29. Trust installation is privileged
Adding a local CA to trusted macOS certificate stores may require elevated authorization.
This operation belongs behind the privileged helper boundary.
Conceptually:
vaelend
    │
    │ installTrustedCA(reference)
    ▼
helper
    │
    ▼
macOS trust configuration
The helper must validate that the certificate is specifically the expected Vaelen CA.

30. No arbitrary certificate trust API
Bad:
trustCertificate(path: String)
with unrestricted caller-controlled input.
Preferred:
installVaelenLocalCA(expected fingerprint)
or another constrained representation.
The helper should not become a generic mechanism for trusting arbitrary certificates as root.

31. CA identity
Vaelen must record the identity of the local CA it created.
At minimum this should include a stable cryptographic fingerprint.
Conceptually:
Vaelen Local CA

SHA-256 fingerprint:
AB:CD:...
Trust removal should verify identity before modifying system trust.

32. CA private key
The CA private key is sensitive.
Requirements:
	•	user-scoped access;
	•	restrictive filesystem permissions or appropriate secure storage;
	•	never included in logs;
	•	never transmitted to unrelated clients;
	•	never exposed through val status --json;
	•	not accessible to community module manifests.
The exact storage strategy must be validated against the chosen TLS provider.

33. CA generation
The CA should be generated locally.
Vaelen must not ship one universal private CA key shared by every installation.
Each Vaelen installation/user environment gets its own local CA identity.

34. No cloud certificate dependency
Local development HTTPS must not depend on:
Vaelen account
Vaelen server
internet certificate API
public ACME challenge
It is a local capability.

35. Certificate issuance
When a project route requires HTTPS:
project.test
the TLS provider ensures a valid local certificate exists.
Conceptually:
Route desired
     │
     ▼
TLS required
     │
     ▼
certificate available?
     │
 ┌───┴────┐
 yes      no
 │         │
 ▼         ▼
use      issue
This should normally be automatic.

36. Per-host vs wildcard certificates
The implementation may use:
	•	individual host certificates;
	•	wildcard certificates;
	•	provider-managed dynamic issuance.
The architecture does not mandate one strategy yet.
The choice should optimize:
	•	security;
	•	speed;
	•	wildcard project support;
	•	clean lifecycle;
	•	compatibility.

37. HTTPS defaults
Project routing defaults to:
HTTPS enabled
HTTP → HTTPS redirect
unless explicitly disabled.
This should require no per-project administrator authorization once the system-level CA trust relationship is established.

38. Certificate trust status
Core should distinguish:
CA exists

CA trusted

project certificate exists

project certificate valid
These are separate diagnostic states.

39. TLS health
val doctor should be capable of reporting:
TLS

✓ Vaelen Local CA exists
✓ CA fingerprint matches state
✓ CA trusted by macOS
✓ project.test certificate valid
✓ certificate hostname valid
This makes certificate problems diagnosable rather than magical.

40. CA replacement
If the local CA is lost or corrupted, Vaelen may need to generate a replacement.
That operation should be explicit because existing project certificates may become invalid.
Conceptually:
Old CA
   ↓
remove old trust if owned
   ↓
generate new CA
   ↓
install trust
   ↓
reissue local certificates
Vaelen must not silently accumulate trusted obsolete CAs.

41. CA uninstall
During complete Vaelen system removal:
Vaelen-owned CA trust
       ↓
remove
only after verifying the CA identity.
Any private key owned by Vaelen may then be removed according to the selected uninstall/preserve policy.

42. Standard HTTP/HTTPS ports
The desired user experience requires:
http://project.test
https://project.test
without explicit port numbers.
Therefore Vaelen should target:
80
443
for the local router.

43. Router should remain unprivileged
The preferred architecture is:
Caddy
  user process
rather than:
Caddy
  root process
Vaelen must investigate supported macOS mechanisms that allow a user-owned router to receive standard HTTP/HTTPS traffic safely.

44. Privileged-port strategy requires prototype validation
The exact implementation for ports 80 and 443 is intentionally not fixed in this ADR.
Potential approaches may involve:
	•	macOS-supported socket/service mechanisms;
	•	narrowly scoped privileged setup;
	•	packet forwarding/redirection;
	•	controlled capability mechanisms available on supported macOS releases.
The chosen solution must satisfy:
Caddy remains user-owned

Core remains user-owned

no generic root proxy

no persistent unnecessary privileged workload

clean uninstall
This is a prototype requirement before v0.1 routing is considered complete.

45. No hidden alternate-port UX
Vaelen should not silently fall back from:
443
to:
8443
and pretend nothing changed.
If standard ports cannot be acquired, the state must be explicit.
Example:
Router degraded

Port 443 is occupied by:
nginx
PID 8214

46. Port conflicts
Before starting the router, Core checks:
80
443
If occupied, Vaelen attempts to identify the process.
Potential output:
HTTPS unavailable.

Port 443 is currently used by:

/Applications/Herd.app/...
PID 8421

Vaelen will not stop this external process automatically.
This is consistent with ADR-0001 process ownership.

47. Coexistence with Herd and Valet
Vaelen should assume developers may already have:
Herd
Valet
Homebrew nginx
dnsmasq
Caddy
Apache
installed.
Initial setup must diagnose conflicts before changing system state.
It should never automatically:
kill Herd
uninstall Valet
remove Homebrew packages
overwrite unknown resolver configuration

48. Migration UX
A future setup flow may say:
Vaelen detected another local development environment.

Port 80:
Herd nginx

Port 443:
Herd nginx

.test DNS:
existing resolver

Vaelen cannot become active until these conflicts are resolved.
It may offer instructions or safe explicit actions where ownership permits.
It must not seize the machine.

49. DNS and TLS setup are platform capabilities
Modules do not individually request:
edit resolver
trust certificate
bind system ports
Projects declare needs such as:
domain
HTTPS
Platform capabilities satisfy those needs.
This keeps module manifests away from root-level system configuration.

50. Capability status
Core should expose system capability state.
Conceptually:
DNS
    configured
    healthy
    ownership: vaelen

TLS
    CA available
    trusted
    healthy

Routing
    standard ports available
    healthy
The GUI and CLI consume the same state.

51. First-run setup
Initial Vaelen setup should determine required platform capabilities.
Conceptually:
Welcome to Vaelen

System setup:

• Configure .test domains
• Install Vaelen Local CA
• Enable local HTTP/HTTPS

macOS may request administrator authorization.
Authorization should be requested only when the user initiates setup requiring it.

52. Progressive permissions
Vaelen should not request every possible permission on first launch merely because a future module might need it.
For the v0.1 web environment, only platform capabilities genuinely required for:
.test
HTTPS
routing
should be configured.
Future features request their own permissions when installed or enabled.

53. No root requirement for module installation
Installing:
PHP
Redis
Mailpit
MySQL
into:
~/Library/Application Support/Vaelen/
must not require root merely because Vaelen has a privileged helper available.
Ordinary package management remains user-level.

54. No root requirement for service lifecycle
These operations should not require authorization:
val service start mysql
val service stop mysql
val php use 8.4
val module install mailpit
System privilege should feel exceptional.

55. Helper version compatibility
The privileged helper and Core must have an explicit compatibility model.
Core must not send operations unsupported by an older helper.
Conceptually:
Core helper API:
2

Installed helper API:
1
should result in a clear update requirement.

56. Helper updates
Updating the privileged helper may require system authorization depending on macOS installation mechanisms.
Vaelen should minimize helper updates by keeping the privileged interface small and stable.
Module releases should not normally require helper changes.
This is another reason module-specific behavior must not live there.

57. Helper logging
Privileged operations should be auditable locally.
Example:
Installed .test resolver
Removed .test resolver
Installed Vaelen Local CA trust
Removed Vaelen Local CA trust
Logs must not include:
	•	passwords;
	•	private keys;
	•	secret tokens.

58. Privileged operation idempotency
System operations should be idempotent where practical.
For example:
installVaelenResolver()
when the correct Vaelen-owned resolver already exists should succeed without unnecessary mutation.
Likewise:
removeVaelenResolver()
when no Vaelen-owned resolver exists should not delete unrelated configuration.

59. Privileged failure recovery
System modifications should be applied carefully enough that interrupted operations do not leave ambiguous state.
Where possible:
inspect
   ↓
prepare
   ↓
perform atomic/safe change
   ↓
verify
   ↓
record ownership
If verification fails, Core should report the system as degraded rather than assuming success.

60. System capability reconciliation
At Core startup or during diagnostics, Vaelen may compare recorded system capability state against actual macOS state.
Example:
State says:
.test resolver installed

Actual:
resolver missing
Result:
DNS capability:
DEGRADED
Vaelen should not automatically perform privileged repair without appropriate user intent.

61. val doctor --fix
A future:
val doctor --fix
may repair deterministic safe issues.
Privileged repairs may trigger macOS authorization where required.
--fix must not become:
overwrite whatever is in the way
Ownership rules still apply.

62. Security of module ecosystem
Future community modules must not gain privileged helper access directly.
Conceptually:
Community Module
       │
       ▼
   Vaelen Core
       │
       ✕ arbitrary root access
Only predefined Core system capabilities may cross the privileged boundary.

63. Security of project configuration
A cloned repository containing:
vaelen.yml
must not be able to cause arbitrary privileged operations merely because the developer runs:
val up
Project configuration may request:
HTTPS
.test route
Core maps those to approved platform capabilities.
The project cannot provide arbitrary root instructions.

64. Trust boundary diagram
UNTRUSTED / USER-CONTROLLED INPUT

vaelen.yml
module config
project paths
CLI arguments
future community manifests
        │
        ▼
┌───────────────────────────┐
│       VAELEN CORE         │
│                           │
│ validation                │
│ policy                    │
│ ownership                 │
│ capability resolution     │
└─────────────┬─────────────┘
              │
              │ narrow typed requests
              ▼
┌───────────────────────────┐
│   PRIVILEGED HELPER       │
│                           │
│ validate again            │
│ fixed capabilities only   │
└─────────────┬─────────────┘
              │
              ▼
            macOS

65. Threat model
The privileged architecture should explicitly defend against:
Path injection
A malicious project tries to make the helper overwrite arbitrary root files.
Command injection
A module or project attempts to convert configuration into root shell execution.
Symlink attacks
A supposedly Vaelen-owned path points somewhere unexpected.
Confused deputy
An untrusted client attempts to convince the helper to perform a legitimate privileged operation on an illegitimate target.
Stale ownership
Vaelen deletes a system artifact that another tool has replaced.
Certificate substitution
A different certificate is substituted where Vaelen expects its local CA.
Client impersonation
An unrelated process attempts to call the privileged helper.

66. Privileged helper acceptance test
Before adding any new helper method, answer:
	1	Why does this require root?
	2	Can macOS provide the capability without persistent root execution?
	3	Can the operation be expressed more narrowly?
	4	Can input paths be eliminated?
	5	Can caller-controlled shell commands be eliminated?
	6	Can the helper independently validate ownership?
	7	Can the operation be reversed?
	8	Can Vaelen verify success?
	9	What happens during uninstall?
	10	Could a malicious vaelen.yml trigger this operation?
If the security story is unclear, the capability does not belong in the helper yet.

67. Consequences
Positive
Core remains safe by default
Almost all Vaelen code executes as the developer.
Developer files remain user-owned
Normal services do not create root-owned project files.
Privilege is inspectable
The root boundary is small enough to audit.
Modules remain unprivileged
Adding modules does not expand root authority automatically.
DNS becomes dynamic
No per-project /etc/hosts mutation is necessary.
HTTPS becomes normal
Projects can use trusted local HTTPS with minimal setup.
Uninstall is tractable
System modifications are explicitly tracked.

68. Costs
Vaelen must implement and maintain:
	•	privileged helper installation;
	•	authenticated XPC;
	•	resolver management;
	•	ownership tracking;
	•	local CA lifecycle;
	•	certificate trust integration;
	•	port conflict diagnostics;
	•	system capability reconciliation.
macOS security APIs and helper installation behavior may also evolve between OS versions.
This is unavoidable complexity for a polished native development environment.

69. Alternatives Considered
Run Vaelen Core as root
Rejected.
Excessive privilege and poor filesystem ownership behavior.

Use sudo commands from Core
Rejected as the architectural model.
This encourages arbitrary privileged shell execution and poor authorization UX.

Ask for password in Vaelen
Rejected completely.
macOS owns authentication.

Modify /etc/hosts per project
Rejected.
Poor dynamic behavior, repeated privileged writes, no wildcard support, and difficult ownership.

Disable HTTPS by default
Rejected.
Modern local development should model HTTPS as normal infrastructure.

Run the router as root
Rejected as the preferred architecture.
The router should remain user-owned if a reliable macOS mechanism permits it.

Use public certificate authorities
Rejected.
.test development is local and should not depend on public certificate infrastructure.

Universal Vaelen CA bundled with application
Rejected.
Every installation must have its own locally generated CA identity.

70. Open Implementation Questions
	1	Exact supported macOS mechanism for privileged helper installation and lifecycle.
	2	Exact XPC client identity validation.
	3	Exact local DNS responder implementation.
	4	Whether macOS resolver configuration can reliably target a non-privileged DNS port.
	5	Exact strategy for ports 80 and 443 while keeping Caddy unprivileged.
	6	Exact Caddy/local-CA integration.
	7	CA private-key storage location.
	8	Whether macOS Keychain is appropriate for CA key material or whether provider-managed protected files are preferable.
	9	Browser-specific trust behavior beyond macOS system trust.
	10	Exact resolver ownership metadata.
	11	Conflict behavior with Herd/Valet during first-run migration.
	12	Helper update mechanism.
	13	Whether system capability repair should ever occur automatically.
	14	Exact uninstall sequence for helper + CA + resolver.
	15	Supported minimum macOS version, which may affect available security/service-management APIs.
These require prototypes before v0.1 is considered production-ready.

71. Invariants Established by This ADR
	1	vaelend never runs as root.
	2	Ordinary Vaelen modules and services run as the logged-in user.
	3	Privilege exists behind a separate narrow helper.
	4	The helper never exposes arbitrary root command execution.
	5	The helper independently validates privileged requests.
	6	XPC protects the Core-to-helper boundary.
	7	Vaelen never handles administrator passwords itself.
	8	.test is the default development TLD.
	9	Vaelen does not maintain per-project /etc/hosts entries.
	10	DNS is a platform capability separate from routing.
	11	The local DNS responder should remain unprivileged where technically possible.
	12	Existing resolver configuration is inspected before modification.
	13	Vaelen removes only resolver state it can establish it owns.
	14	HTTPS is enabled by default for normal web projects.
	15	Local HTTPS does not require a Vaelen account or cloud service.
	16	Each Vaelen environment uses a locally generated CA identity.
	17	Vaelen never ships a universal CA private key.
	18	CA trust operations are narrowly constrained.
	19	The privileged helper cannot trust arbitrary caller-selected certificates.
	20	CA identity is verified before trust removal.
	21	CA private keys never appear in logs or ordinary status output.
	22	The router should remain a user process.
	23	Standard ports 80 and 443 are the desired default UX.
	24	Failure to acquire standard ports is explicit, not silently hidden behind alternate ports.
	25	Vaelen never automatically kills external processes to reclaim ports.
	26	Herd, Valet, Homebrew, and other external environments remain externally owned.
	27	Modules cannot directly invoke privileged helper operations.
	28	Project configuration cannot express arbitrary privileged commands.
	29	System modifications caused by Vaelen are recorded.
	30	Privileged capability expansion requires deliberate architectural review.

Summary
Vaelen should feel deeply integrated with macOS without becoming unnecessarily privileged.
The normal environment remains:
Developer
   │
   ▼
Vaelen Core
   │
   ├── Caddy
   ├── PHP
   ├── MySQL
   ├── Redis
   └── project processes

all running as the user
Only narrow system integration crosses the privilege boundary:
vaelend
   │
   │ authenticated typed XPC
   ▼
Privileged Helper
   │
   ├── .test resolver setup
   ├── Vaelen Local CA trust
   └── approved routing setup
The central rule is:
Vaelen does not run privileged. Vaelen requests specific privileged capabilities when macOS requires them.
DNS establishes where .test goes.
The Router establishes which project receives the request.
TLS establishes trusted local HTTPS.
Modules and projects consume those capabilities without acquiring root authority themselves.
