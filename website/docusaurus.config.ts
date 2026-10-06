import { themes as prismThemes } from 'prism-react-renderer';
import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Homelab',
  tagline: 'Smadja Kubernetes homelab',
  favicon: 'img/favicon.ico',

  url: 'https://homelab.orkestack.com',
  baseUrl: '/',

  organizationName: 'SmadjaPaul',
  projectName: 'kube-ops',

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: 'sidebars.ts',
          editUrl: 'https://github.com/SmadjaPaul/kube-ops/edit/main/website/',
          exclude: ['styles/**'],
        },
        theme: {
          customCss: './src/css/custom.css',
        },
        blog: false,
        sitemap: {
          changefreq: 'weekly',
          priority: 0.5,
          ignorePatterns: ['/tags/**'],
          filename: 'sitemap.xml',
        },
      } satisfies Preset.Options,
    ],
  ],
  themes: [
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      {
        hashed: true,
        docsRouteBasePath: 'docs',
        highlightSearchTermsOnTargetPage: true,
      },
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: false,
      respectPrefersColorScheme: false,
    },
    metadata: [
      { name: 'keywords', content: 'kubernetes, homelab, gitops' },
      { name: 'twitter:card', content: 'summary_large_image' },
    ],
    image: 'img/logo.png',
    navbar: {
      title: 'Homelab',
      logo: {
        alt: 'Homelab Logo',
        src: 'img/logo.png',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'DocumentationSidebar',
          position: 'left',
          label: 'Documentation',
        },
        {
          href: 'https://github.com/SmadjaPaul/kube-ops',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Intro',
              to: '/docs/intro',
            },
          ],
        },
        {
          title: 'Source',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/SmadjaPaul/kube-ops',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} SmadjaPaul. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
