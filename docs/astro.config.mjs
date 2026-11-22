// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages resolves /api/ to api/index.html. Vite serves public/ as plain
// files and does not resolve directory indexes, so `bun run dev` would 404 on
// the API reference while the deployed site works. Rewrite that one request in
// the dev server only; the build is untouched.
const devApiIndex = {
  name: 'pgzx-dev-api-index',
  hooks: {
    /** @param {{ server: { middlewares: { use: (fn: (req: any, res: any, next: () => void) => void) => void } } }} ctx */
    'astro:server:setup': ({ server }) => {
      server.middlewares.use((req, _res, next) => {
        const [path, query] = String(req.url).split('?');
        if (path === '/api' || path === '/api/') {
          req.url = `/api/index.html${query ? `?${query}` : ''}`;
        }
        next();
      });
    },
  },
};

// NOTE: this must stay an object, not `defineConfig(({ command }) => ...)`.
// With the callback form, Astro 7.4's dev server returns 404 for every route.
//
// The site is served from the domain root (docs/public/CNAME), so there is no
// `base`: every link, generated or written by hand, is /<route>/.
export default defineConfig({
  site: 'https://pgzx.barddoo.com',
  integrations: [
    devApiIndex,
    starlight({
      title: 'pgzx',
      description: 'Create PostgreSQL extensions with Zig.',
      logo: {
        light: './src/assets/pgzx-logo-light.svg',
        dark: './src/assets/pgzx-logo-dark.svg',
        alt: 'pgzx',
      },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/barddoo/pgzx' }],
      editLink: {
        baseUrl: 'https://github.com/barddoo/pgzx/edit/main/docs/',
      },
      // The API reference used to live at the site root (#docs.pgzx, #A;...).
      // Keep old links and bookmarks working now that it lives under /api/ and
      // uses the current fully-qualified-name anchors (#pgzx.pgzx.elog.Log).
      head: [
        {
          tag: 'script',
          content: `{const A='/api/',h=location.hash;if(h.startsWith('#docs.pgzx'))location.replace(A+'#pgzx');else if(h.startsWith('#A;')){const [pkg,rest]=h.slice(3).split(':');location.replace(A+'#'+(rest.includes('.')?pkg+'.'+pkg+'.'+rest:pkg+'.'+rest));}}`,
        },
      ],
      sidebar: [
        {
          label: 'Getting started',
          items: ['start/install', 'start/quickstart'],
        },
        {
          label: 'Guides',
          items: [
            'guides/function-manager',
            'guides/logging-and-errors',
            'guides/memory-contexts',
            'guides/set-returning-functions',
            'guides/sql-schema',
            'guides/testing',
            'guides/examples',
          ],
        },
        {
          label: 'Build system',
          items: ['build-system', 'build-system/internals'],
        },
        {
          label: 'Contributing',
          items: [
            'contributing/environment',
            'contributing/build-and-test',
            'contributing/debugging',
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'API reference', link: '/api/' },
            {
              label: 'GitHub',
              link: 'https://github.com/barddoo/pgzx',
              attrs: { target: '_blank' },
            },
          ],
        },
      ],
    }),
  ],
});
