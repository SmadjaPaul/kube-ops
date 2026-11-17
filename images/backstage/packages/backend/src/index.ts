import { createBackend } from '@backstage/backend-defaults';

// Plateforme IDP hebergee (provisoire, svc-backstage) : catalogue + Scaffolder + search + MCP actions
// (agents) + framework permissions. Pas de guest, pas d'OIDC humain pour l'instant : seuls les tokens
// agents (externalAccess) donnent acces. Pas de kubernetes, pas d'Argo CD, pas de TechDocs.
const backend = createBackend();

backend.add(import('@backstage/plugin-app-backend'));

// scaffolder
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));
backend.add(import('@roadiehq/scaffolder-backend-module-utils'));

// auth : service principals uniquement (externalAccess dans app-config.yaml)
backend.add(import('@backstage/plugin-auth-backend'));

// catalogue
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);

// permissions : framework + politique (DENY par defaut)
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(import('./permissionPolicy'));

// search (catalogue)
backend.add(import('@backstage/plugin-search-backend'));
backend.add(import('@backstage/plugin-search-backend-module-catalog'));

// MCP actions (agents)
backend.add(import('@backstage/plugin-mcp-actions-backend'));

backend.start();
