import '../core/workflow.dart';
import '../core/layout.dart';

/// Starter workflows shown in "New from template".
class WorkflowTemplate {
  const WorkflowTemplate({required this.title, required this.description, required this.icon, required this.create});

  final String title;

  /// Node type whose icon represents the template.
  final String icon;
  final String description;
  final Workflow Function() create;

  /// A fresh copy, laid out top to bottom for a portrait phone.
  Workflow build() {
    final wf = create();
    layoutVertically(wf, (n) => n.type.startsWith('trigger.'));
    return wf;
  }
}

Workflow blankWorkflow() => Workflow(
  id: newId('wf_'),
  name: 'My workflow',
  nodes: [WorkflowNode(id: newId('n_'), name: 'When clicking Run', type: 'trigger.manual', x: 1884, y: 40)],
);

final templates = <WorkflowTemplate>[
  WorkflowTemplate(
    title: 'Save shared text to my notes',
    icon: 'rag.add',
    description: 'Share any text or link to FlowDroid and it is added to a searchable knowledge base, offline.',
    create: () {
      final share = WorkflowNode(id: newId('n_'), name: 'Shared to FlowDroid', type: 'trigger.share', x: 80, y: 240);
      final add = WorkflowNode(
        id: newId('n_'),
        name: 'Add to my notes',
        type: 'rag.add',
        params: {
          'collection': 'my-notes',
          'text': '{{ \$json.text }}',
          'source': '{{ \$json.file.name ?? \$json.subject ?? \$now }}',
          'embedder': 'local',
          'chunkSize': 800,
          'overlap': 100,
        },
        x: 320,
        y: 240,
      );
      final done = WorkflowNode(
        id: newId('n_'),
        name: 'Saved',
        type: 'android.notify',
        params: {
          'title': 'Saved to my notes',
          'body': '{{ \$json.knowledge.chunks }} part(s) from {{ \$json.knowledge.source }}',
        },
        x: 560,
        y: 240,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Save shared text to my notes',
        nodes: [share, add, done],
        connections: [
          Connection(from: share.id, to: add.id),
          Connection(from: add.id, to: done.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Ask my notes (RAG)',
    icon: 'rag.search',
    description: 'Finds the parts of your notes that answer a question and lets AI answer from them only.',
    create: () {
      final start = WorkflowNode(id: newId('n_'), name: 'When clicking Run', type: 'trigger.manual', x: 80, y: 240);
      final ask = WorkflowNode(
        id: newId('n_'),
        name: 'Question',
        type: 'core.set',
        params: {
          'fields': [
            {'name': 'question', 'value': 'What is the wifi password?'},
          ],
        },
        x: 320,
        y: 240,
      );
      final search = WorkflowNode(
        id: newId('n_'),
        name: 'Search my notes',
        type: 'rag.search',
        params: {'collection': 'my-notes', 'query': '{{ \$json.question }}', 'topK': 4, 'minScore': 0},
        x: 560,
        y: 240,
      );
      final answer = WorkflowNode(
        id: newId('n_'),
        name: 'Answer',
        type: 'ai.chat',
        params: {
          'provider': 'anthropic',
          'system': 'Answer only from the notes given. If they do not contain the answer, say you could not find it.',
          'prompt': 'Notes:\n{{ \$json.knowledge.context }}\n\nQuestion: {{ \$json.question }}',
          'timeout': 120,
        },
        x: 800,
        y: 240,
      );
      final show = WorkflowNode(
        id: newId('n_'),
        name: 'Show answer',
        type: 'android.notify',
        params: {'title': 'From your notes', 'body': '{{ \$json.text }}'},
        x: 1040,
        y: 240,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Ask my notes',
        nodes: [start, ask, search, answer, show],
        connections: [
          Connection(from: start.id, to: ask.id),
          Connection(from: ask.id, to: search.id),
          Connection(from: search.id, to: answer.id),
          Connection(from: answer.id, to: show.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Low battery alert',
    icon: 'android.battery',
    description: 'Checks the battery every 15 minutes and notifies you below 20%.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'Every 15 minutes',
        type: 'trigger.schedule',
        params: {'mode': 'interval', 'minutes': 15},
        x: 80,
        y: 240,
      );
      final battery = WorkflowNode(id: newId('n_'), name: 'Battery', type: 'android.battery', x: 320, y: 240);
      final check = WorkflowNode(
        id: newId('n_'),
        name: 'Below 20%?',
        type: 'core.if',
        params: {
          'conditions': [
            {'left': '{{ \$json.battery.level }}', 'op': 'lt', 'right': '20'},
            {'left': '{{ \$json.battery.charging }}', 'op': 'isFalse'},
          ],
        },
        x: 560,
        y: 240,
      );
      final notify = WorkflowNode(
        id: newId('n_'),
        name: 'Warn me',
        type: 'android.notify',
        params: {'title': 'Battery low', 'body': 'Only {{ \$json.battery.level }}% left. Time to charge.'},
        x: 800,
        y: 180,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Low battery alert',
        nodes: [trigger, battery, check, notify],
        connections: [
          Connection(from: trigger.id, to: battery.id),
          Connection(from: battery.id, to: check.id),
          Connection(from: check.id, to: notify.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Webhook to notification',
    icon: 'trigger.webhook',
    description: 'Another device POSTs JSON to your phone; you get a notification and a reply.',
    create: () {
      final hook = WorkflowNode(
        id: newId('n_'),
        name: 'Incoming webhook',
        type: 'trigger.webhook',
        params: {'path': 'notify', 'method': 'POST'},
        x: 80,
        y: 240,
      );
      final notify = WorkflowNode(
        id: newId('n_'),
        name: 'Notify',
        type: 'android.notify',
        params: {'title': '{{ \$json.body.title ?? "Webhook" }}', 'body': '{{ \$json.body.message }}'},
        x: 320,
        y: 240,
      );
      final respond = WorkflowNode(
        id: newId('n_'),
        name: 'Reply',
        type: 'core.respond',
        params: {'status': 200, 'body': '{{ ["received", \$json.body.title] }}'},
        x: 560,
        y: 240,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Webhook to notification',
        nodes: [hook, notify, respond],
        connections: [
          Connection(from: hook.id, to: notify.id),
          Connection(from: notify.id, to: respond.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Morning quote',
    icon: 'http.request',
    description: 'Fetches a random quote from an API at 9:00 and reads it aloud.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'Every day at 9:00',
        type: 'trigger.schedule',
        params: {'mode': 'cron', 'cron': '0 9 * * *'},
        x: 80,
        y: 240,
      );
      final fetch = WorkflowNode(
        id: newId('n_'),
        name: 'Get quote',
        type: 'http.request',
        params: {'method': 'GET', 'url': 'https://dummyjson.com/quotes/random'},
        x: 320,
        y: 240,
      );
      final notify = WorkflowNode(
        id: newId('n_'),
        name: 'Show quote',
        type: 'android.notify',
        params: {'title': 'Quote of the day', 'body': '"{{ \$json.quote }}" ({{ \$json.author }})'},
        x: 560,
        y: 240,
      );
      final speak = WorkflowNode(
        id: newId('n_'),
        name: 'Read it',
        type: 'android.speak',
        params: {'text': '{{ \$json.quote }}'},
        x: 800,
        y: 240,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Morning quote',
        nodes: [trigger, fetch, notify, speak],
        connections: [
          Connection(from: trigger.id, to: fetch.id),
          Connection(from: fetch.id, to: notify.id),
          Connection(from: notify.id, to: speak.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Share my location',
    icon: 'android.location',
    description: 'Gets your GPS position, copies a map link and opens it.',
    create: () {
      final trigger = WorkflowNode(id: newId('n_'), name: 'When clicking Run', type: 'trigger.manual', x: 80, y: 240);
      final locate = WorkflowNode(id: newId('n_'), name: 'Where am I', type: 'android.location', x: 320, y: 240);
      final link = WorkflowNode(
        id: newId('n_'),
        name: 'Build link',
        type: 'core.set',
        params: {
          'fields': [
            {
              'name': 'url',
              'value': 'https://maps.google.com/?q={{ \$json.location.latitude }},{{ \$json.location.longitude }}',
            },
          ],
        },
        x: 560,
        y: 240,
      );
      final copy = WorkflowNode(
        id: newId('n_'),
        name: 'Copy link',
        type: 'android.clipboardWrite',
        params: {'text': '{{ \$json.url }}'},
        x: 800,
        y: 240,
      );
      final open = WorkflowNode(
        id: newId('n_'),
        name: 'Open map',
        type: 'android.openUrl',
        params: {'url': '{{ \$json.url }}'},
        x: 1040,
        y: 240,
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Share my location',
        nodes: [trigger, locate, link, copy, open],
        connections: [
          Connection(from: trigger.id, to: locate.id),
          Connection(from: locate.id, to: link.id),
          Connection(from: link.id, to: copy.id),
          Connection(from: copy.id, to: open.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Telegram AI assistant',
    icon: 'ai.chat',
    description: 'Answers every message to your Telegram bot with Claude. Add a bot token and an Anthropic key.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'Telegram message',
        type: 'trigger.telegram',
        params: {'credential': '', 'chatId': ''},
      );
      final ai = WorkflowNode(
        id: newId('n_'),
        name: 'Ask Claude',
        type: 'ai.chat',
        params: {
          'provider': 'anthropic',
          'credential': '',
          'model': '',
          'system': 'You are a helpful assistant. Reply briefly, in plain text.',
          'prompt': '{{ \$json.text }}',
          'json': false,
          'timeout': 120,
        },
      );
      final reply = WorkflowNode(
        id: newId('n_'),
        name: 'Reply',
        type: 'telegram.send',
        params: {
          'credential': '',
          'chatId': '{{ \$node["Telegram message"].json.chat.id }}',
          'text': '{{ \$json.text }}',
          'parseMode': 'none',
        },
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Telegram AI assistant',
        nodes: [trigger, ai, reply],
        connections: [
          Connection(from: trigger.id, to: ai.id),
          Connection(from: ai.id, to: reply.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Daily server check',
    icon: 'system.command',
    description: 'Every morning checks that a website answers and notifies you with the result.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'Every morning',
        type: 'trigger.schedule',
        params: {'mode': 'cron', 'cron': '0 8 * * *'},
      );
      final command = WorkflowNode(
        id: newId('n_'),
        name: 'Check',
        type: 'system.command',
        params: {
          'target': 'phone',
          'command': 'ping -c 1 -W 5 example.com >/dev/null && echo up || echo down',
          'workdir': '',
          'timeout': 60,
          'ignoreExitCode': true,
        },
      );
      final notify = WorkflowNode(
        id: newId('n_'),
        name: 'Tell me',
        type: 'android.notify',
        params: {'title': 'Server check', 'body': 'example.com is {{ \$json.stdout.trim() }}'},
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Daily server check',
        nodes: [trigger, command, notify],
        connections: [
          Connection(from: trigger.id, to: command.id),
          Connection(from: command.id, to: notify.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Research assistant',
    icon: 'ai.agent',
    description: 'Ask by sharing text to FlowDroid; Claude searches the web and notifies you with the answer.',
    create: () {
      final trigger = WorkflowNode(id: newId('n_'), name: 'Shared to FlowDroid', type: 'trigger.share');
      final agent = WorkflowNode(
        id: newId('n_'),
        name: 'Research',
        type: 'ai.agent',
        params: {
          'credential': '',
          'model': '',
          'system': 'Answer in at most five sentences. Name your sources.',
          'prompt': '{{ \$json.text }}',
          'tools': <Object?>[],
          'webSearch': true,
          'maxSteps': 10,
          'timeout': 120,
        },
      );
      final notify = WorkflowNode(
        id: newId('n_'),
        name: 'Show answer',
        type: 'android.notify',
        params: {'title': 'Research done', 'body': '{{ \$json.text }}'},
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Research assistant',
        nodes: [trigger, agent, notify],
        connections: [
          Connection(from: trigger.id, to: agent.id),
          Connection(from: agent.id, to: notify.id),
        ],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Forward SMS codes to Telegram',
    icon: 'trigger.sms',
    description: 'Sends every SMS that contains “code” to your Telegram chat.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'SMS received',
        type: 'trigger.sms',
        params: {'from': '', 'contains': 'code'},
      );
      final send = WorkflowNode(
        id: newId('n_'),
        name: 'Forward',
        type: 'telegram.send',
        params: {
          'credential': '',
          'chatId': '',
          'text': 'SMS from {{ \$json.from }}: {{ \$json.text }}',
          'parseMode': 'none',
        },
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Forward SMS codes to Telegram',
        nodes: [trigger, send],
        connections: [Connection(from: trigger.id, to: send.id)],
      );
    },
  ),
  WorkflowTemplate(
    title: 'Save new posts to a phone table',
    icon: 'trigger.rss',
    description: 'Checks a feed every 30 minutes and keeps each new post in the “posts” table.',
    create: () {
      final trigger = WorkflowNode(
        id: newId('n_'),
        name: 'New post',
        type: 'trigger.rss',
        params: {'url': 'https://hnrss.org/frontpage', 'minutes': 30},
      );
      final save = WorkflowNode(
        id: newId('n_'),
        name: 'Save post',
        type: 'db.table',
        params: {'operation': 'insert', 'table': 'posts', 'filters': <Object?>[], 'row': '{{ \$json }}', 'limit': 100},
      );
      return Workflow(
        id: newId('wf_'),
        name: 'Save new posts',
        nodes: [trigger, save],
        connections: [Connection(from: trigger.id, to: save.id)],
      );
    },
  ),
];
