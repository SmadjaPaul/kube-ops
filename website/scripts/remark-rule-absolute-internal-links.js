import {visit} from 'unist-util-visit';

const message =
  'Internal documentation links must be relative; avoid root-relative URLs.';

/**
 * Reject root-relative links in Markdown documentation.
 *
 * Docusaurus documentation is versioned and can be hosted below a path. A
 * link such as /docs/guide bypasses that context, while ./guide.md preserves
 * the relationship between the source documents.
 */
export default function remarkRuleAbsoluteInternalLinks() {
  return function lintAbsoluteInternalLinks(tree, file) {
    visit(tree, 'link', (node) => {
      if (typeof node.url === 'string' && node.url.startsWith('/') && !node.url.startsWith('//')) {
        file.message(message, node, 'remark-rule-absolute-internal-links');
      }
    });
  };
}
