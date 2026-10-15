# Give a tenant its own Grafana organisation

Applies to a tenant in `services.victoriaStack.tenants` (see
[0032](../decisions/0032-tenants-in-token-files.md)) whose users should see that
tenant's data in Grafana and nothing else. Grafana OSS cannot create
organisations or restrict a datasource to some users of an organisation, so the
split is one organisation per tenant: you create the organisation by hand, and
the module provisions the tenant's datasources into it. The datasources go
through vmauth's read tier with the tenant's own token
([0029](../decisions/0029-grafana-datasources-through-vmauth-read-tier.md)), so
they can only read that tenant, whatever a Grafana user types into Explore.

The steps below are run by the test `grafana-tenant-orgs-runbook`
(`tests/grafana-tenant-orgs.nix`, a VM): steps 1 to 4 with the API calls shown
here, the missing-organisation failure and a token rotation. The clicks in the
Grafana UI are not automated.

Placeholders: `<tenant>` is the tenant name, `<org-id>` the number Grafana
gives the organisation, `grafana.example.internal` your Grafana host,
`<admin-user>` a Grafana server admin.

## Order matters: create the organisation first

If `grafanaOrgId` names an organisation that does not exist, Grafana fails at
start (`[org.notFound] failed to get org by ID: <org-id>` in its journal) and
systemd restarts it in a loop. While it loops its API is down, so the
organisation cannot be created then. Create it first, with Grafana running,
and set `grafanaOrgId` afterwards. If it is already looping (the organisation
was deleted, or the id is wrong), remove `grafanaOrgId` and `readTokenFile`
from the tenant, deploy, and start again at step 2.

## Procedure

1. **Declare the tenant and its read token.** Create a file with one random
   bearer token for this tenant's Grafana datasources, list the same token in
   vmauth's read tokens with `tenant: <tenant>`, and deploy. Do not set
   `grafanaOrgId` yet.

   ```nix
   {
     imports = [ victoria-stack-module.nixosModules.victoriaStack ];
     services.victoriaStack = {
       tenants.team-a.accountId = 7;
       vmauth.readTokensFile = "/run/secrets/vmauth-read-tokens.yaml";
     };
   }
   ```

   ```yaml
   # vmauth-read-tokens.yaml
   tokens:
     - token: "team-a-grafana-secret"   # the content of the token file
       tenant: team-a
   ```

2. **Create the organisation in Grafana.** In the UI: Administration, General,
   Organizations, New org; the organisations list shows the id. Or with the
   API as a server admin:

   ```sh
   curl -X POST -u '<admin-user>:<admin-password>' \
     -H 'Content-Type: application/json' -d '{"name": "<tenant>"}' \
     https://grafana.example.internal/api/orgs
   # {"message":"Organization created","orgId":<org-id>}
   ```

   Add the tenant's users to the organisation with the role Viewer or Editor
   (Administration, Users and access). Every member of the organisation can
   query every datasource in it. Do not make a tenant's user Admin of its
   organisation: an organisation Admin can add a datasource that points at any
   URL, including the backends directly, past vmauth's tenant tokens, and
   Grafana OSS cannot prevent that. Viewers and Editors cannot create
   datasources.

   By default Grafana adds every new user to the main organisation (id 1) as a
   Viewer, where the main datasources are, and that user can query them through
   Grafana's datasource API. Once a tenant has `grafanaOrgId` (step 3), the
   module sets Grafana's `GF_USERS_AUTO_ASSIGN_ORG_ROLE` to `None`: a new user is
   still listed in the main organisation, but with no rights there (the
   datasource API answers 403), and organisation ids do not shift. Add the user
   to their tenant organisation as in this step. Do not use
   `services.grafana.settings.users.auto_assign_org = false`: Grafana then gives
   every new user a personal organisation of their own as Admin (which can add
   datasources, see above) and shifts the organisation ids.

3. **Set `grafanaOrgId` and `readTokenFile` and deploy.** Both together, or the
   build stops. The id must not be 1 (the organisation of the main
   datasources) and must be different for every tenant.

   ```nix
   {
     imports = [ victoria-stack-module.nixosModules.victoriaStack ];
     services.victoriaStack = {
       tenants.team-a = {
         accountId = 7;
         grafanaOrgId = 2;                                 # the id from step 2
         readTokenFile = "/run/secrets/grafana-team-a-token";  # the token from step 1
       };
     };
   }
   ```

   Deploying changes Grafana's provisioning, so NixOS restarts `grafana.service`.
   Check it is running: `systemctl status grafana.service`.

4. **Verify.**
   - UI: switch to the organisation (profile menu, or the organisation picker),
     then Connections, Data sources lists `VictoriaLogs (<tenant>)`,
     `VictoriaTraces (<tenant>)` and, with metrics on, `VictoriaMetrics (<tenant>)`.
     In Explore, pick one and run a query: it shows only that tenant's data.
     Behind nginx's `/grafana/` sub-path, the two cards on the Connections home
     page link to a doubled path (`/grafana/grafana/connections/...`, a Grafana
     13.1.6 bug); use the sidebar or open `/grafana/connections/datasources`.
   - API (the same check):

     ```sh
     curl -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' \
       https://grafana.example.internal/api/datasources
     ```

     A query through a datasource, for logs:

     ```sh
     curl -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' \
       --data-urlencode 'query=*' \
       https://grafana.example.internal/api/datasources/proxy/uid/vl-<tenant>/select/logsql/query
     ```

   The main organisation keeps only the main datasources.

## Users and the main organisation

The module's `None` role applies to users created after the deploy of step 3
(the test `grafana-tenant-orgs-new-users-have-no-main-org-rights`). What it
does not cover:

- **Users created before.** They stay Viewer in the main organisation and can
  still query the main datasources. For each tenant user: Administration, Users
  and access, Users, the user, Organizations, remove the main organisation (or
  change the role to `None`). Grafana caches permissions: right after the
  removal the main datasource still answered 200, about 30 seconds later 403.
- **Staff who should see the main datasources**, created after the deploy, get
  `None` too. An admin promotes them in the main organisation (to Viewer or
  more).
- **Sign-in through OAuth, LDAP or proxy auth.** Their role mapping may
  override `None` (not tested). Check what role such a user gets in the main
  organisation.
- **Back to Grafana's default** (Viewer for new users):
  `systemd.services.grafana.environment.GF_USERS_AUTO_ASSIGN_ORG_ROLE = lib.mkForce "Viewer";`.
  `services.grafana.settings.users.auto_assign_org_role` does not do it: the
  environment variable wins over it, and the option's type refuses `None`.

## Rotating the token

Replace the content of the tenant's `readTokenFile` and add the new token to
`vmauth.readTokensFile`. A path unit notices the replaced file and restarts
Grafana. Until vmauth knows the new token the tenant's datasources answer 401.

## What the module provisions

Per tenant with both options, into organisation `grafanaOrgId`: one datasource
for each enabled backend, named `<product> (<tenant>)` with uid `vm-<tenant>`,
`vl-<tenant>` or `vt-<tenant>` (a uid is at most 40 characters, so a tenant name
longer than 37 characters is refused). Tenants without the options get nothing.
Removing a tenant's options leaves its datasources in the organisation: the
module only deletes what the current configuration names (the same limit as
disabling a backend, see the note on `prune` in
`nixosModule/victoriaStack/grafana.nix`). Delete them by hand, in Connections,
Data sources, or with
`curl -X DELETE -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' https://grafana.example.internal/api/datasources/uid/<uid>`.
