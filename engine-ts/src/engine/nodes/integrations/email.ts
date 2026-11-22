/**
 * Email over IMAP/SMTP with any provider. Sending is an `email` effect the
 * host carries out with the named credential; receiving is the Email Trigger.
 */

import { fail } from '../../../errors.ts';
import { getKey, type Obj } from '../../../value.ts';
import { filePaths } from '../file_refs.ts';
import { itemsOf, paramText, resumePassThrough, type NodeSpec } from '../spec.ts';
import { credentialName, credentialParam } from './api.ts';

export const emailNodes: NodeSpec[] = [
  {
    type: 'email.send',
    label: 'Send Email',
    group: 'communication',
    description: 'Sends an email per item through your mail server (SMTP).',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['email']),
      { key: 'to', label: 'To', kind: 'text', default: '', hint: 'several: separate with commas' },
      { key: 'subject', label: 'Subject', kind: 'text', default: '' },
      { key: 'text', label: 'Message', kind: 'text', default: '' },
      { key: 'html', label: 'Message is HTML', kind: 'boolean', default: false },
      { key: 'attachments', label: 'Attachments', kind: 'text', default: '', hint: 'file paths, separated by commas; or {{ $json.file.path }}' },
    ],
    run: (run) => {
      const credential = credentialName(run);
      const html = getKey(run.params, 'html') === true;
      const messages = itemsOf(run).map((_, i) => {
        const to = paramText(run, 'to', i);
        if (to === '') fail('NodeError', 'recipient is required');
        const message: Obj = { to, subject: paramText(run, 'subject', i), text: paramText(run, 'text', i), html };
        const attachments = filePaths(run, 'attachments', i);
        if (attachments.length > 0) message['attachments'] = attachments;
        return message;
      });
      return { effect: { type: 'email', credential, messages } };
    },
    resume: resumePassThrough,
  },
];
