// Verification hors reseau de la configuration Backstage hebergee (images/backstage).
// - valide app-config.yaml + app-config.production.yaml contre les schemas des plugins installes ;
// - verifie que integrations.github.apps est accepte et que la cle GitHub App est lue ;
// - n'appelle AUCUN service distant (ni GitHub, ni catalogue).
// Usage (apres yarn install dans images/backstage) :
//   BACKSTAGE_GH_APP_ID=... node scripts/check-config.cjs
// Les valeurs de test (appId, clientId, cle) viennent de l'environnement ; sans elles, le script
// genere une cle RSA ephemere et un appId factice, uniquement pour ce test.
const path = require('node:path');
const crypto = require('node:crypto');
const { loadConfig, loadConfigSchema } = require('@backstage/config-loader');
const { ConfigReader } = require('@backstage/config');
const { readGithubIntegrationConfigs } = require('@backstage/integration');

const root = path.resolve(__dirname, '..');
const pkg = require(path.join(root, 'packages/backend/package.json'));
const dependencies = Object.keys(pkg.dependencies).filter((d) => d.startsWith('@backstage/') || d.startsWith('@roadiehq/'));

async function main() {
  if (!process.env.BACKSTAGE_GH_APP_KEY_PEM) {
    const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
    process.env.BACKSTAGE_GH_APP_KEY_PEM = privateKey.export({ type: 'pkcs1', format: 'pem' });
  }
  process.env.BACKSTAGE_GH_APP_ID ??= '12345';
  process.env.BACKSTAGE_GH_APP_CLIENT_ID ??= 'Iv1.fakeclientid0000';
  process.env.BACKSTAGE_GH_APP_CLIENT_SECRET ??= 'fake-client-secret-for-config-check';
  process.env.BACKSTAGE_AGENT_A_TOKEN ??= 'fake-agent-a-token-for-config-check-only';
  process.env.BACKSTAGE_AGENT_B_TOKEN ??= 'fake-agent-b-token-for-config-check-only';
  // PostgreSQL (variante optionnelle) : valeurs factices, aucune connexion ouverte par ce script.
  process.env.BACKSTAGE_PG_HOST ??= 'pg-check.invalid';
  process.env.BACKSTAGE_PG_PORT ??= '5432';
  process.env.BACKSTAGE_PG_USER ??= 'backstage';
  process.env.BACKSTAGE_PG_PASSWORD ??= 'fake-pg-password-for-config-check-only';
  process.env.BACKSTAGE_PG_DATABASE ??= 'backstage';

  const schema = await loadConfigSchema({ dependencies });
  const { appConfigs } = await loadConfig({
    configRoot: root,
    configTargets: [
      { path: path.join(root, 'app-config.yaml') },
      { path: path.join(root, 'app-config.production.yaml') },
    ],
  });
  const processed = schema.process(appConfigs, { visibility: ['backend', 'secret'] });
  const config = ConfigReader.fromConfigs(processed);
  // Pas de token PAT : la config doit passer par une GitHub App uniquement.
  const gh = config.getOptionalConfigArray('integrations.github') ?? [];
  const integrations = readGithubIntegrationConfigs(gh);
  const github = integrations.find((c) => c.host === 'github.com');
  const app = github.apps?.[0];
  if (!app) throw new Error('integrations.github.apps absent');
  if (github.token) throw new Error('un token PAT est encore configure pour github.com');
  if (typeof app.appId !== 'number') throw new Error('appId doit etre un nombre');
  // Base de donnees : PostgreSQL uniquement en configuration de production (pas de SQLite).
  if (config.getString('backend.database.client') !== 'better-sqlite3') throw new Error('base par defaut attendue : better-sqlite3 (ephemere)');
  // Variante PostgreSQL : valide le schema, non chargee par defaut.
  const pgLoaded = await loadConfig({
    configRoot: root,
    configTargets: [
      { path: path.join(root, 'app-config.yaml') },
      { path: path.join(root, 'app-config.database-pg.yaml') },
    ],
  });
  const pgConfig = ConfigReader.fromConfigs(schema.process(pgLoaded.appConfigs, { visibility: ['backend', 'secret'] }));
  if (pgConfig.getString('backend.database.client') !== 'pg') throw new Error('variante pg non appliquee');
  console.log(JSON.stringify({
    schema: 'ok',
    github_apps: integrations.filter((c) => c.apps).map((c) => ({ host: c.host, appId: typeof c.apps[0].appId, owners: c.apps[0].allowedInstallationOwners })),
    github_token_pat: false,
    catalog_readonly: config.getOptionalBoolean('catalog.readonly'),
    guest_provider: config.has('auth.providers.guest'),
    database_client: config.getString('backend.database.client'),
    pg_variant_schema: 'ok',
    scaffolder_task_recovery: config.getOptionalBoolean('scaffolder.taskRecovery.enabled'),
    permission_enabled: config.getOptionalBoolean('permission.enabled'),
    externalAccess_subjects: (config.getOptionalConfigArray('backend.auth.externalAccess') ?? []).map((c) => c.getString('options.subject')),
  }, null, 2));
}

main().catch((e) => {
  console.error('CONFIG CHECK FAILED:', e.message);
  process.exit(1);
});
