import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/data/templates.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/webhook_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('a POST to an active webhook runs the workflow and returns the Respond node body', () async {
    final repository = await tempRepository();
    final effects = FakeEffects();
    final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
    final server = WebhookServer(repository: repository, runner: runner, port: 0);
    final wf = templates.firstWhere((t) => t.title == 'Webhook to notification').build()..active = true;
    await repository.saveWorkflow(wf);
    await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    final request = await client.post('127.0.0.1', server.boundPort, '/webhook/notify');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'title': 'Hello', 'message': 'From a test'}));
    final response = await request.close();
    final body = await utf8.decodeStream(response);

    expect(response.statusCode, 200);
    expect(jsonDecode(body), ['received', 'Hello']);
    expect(effects.performed.single['notifications'], [
      {'title': 'Hello', 'body': 'From a test'},
    ]);
  });

  test('unknown paths get a 404', () async {
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final server = WebhookServer(repository: repository, runner: runner, port: 0);
    await server.start();
    addTearDown(server.stop);

    final response = await (await HttpClient().get('127.0.0.1', server.boundPort, '/webhook/missing')).close();
    expect(response.statusCode, 404);
  });

  test('a bad request gets a 400 and the server keeps answering', () async {
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final server = WebhookServer(repository: repository, runner: runner, port: 0);
    final wf = templates.firstWhere((t) => t.title == 'Webhook to notification').build()..active = true;
    await repository.saveWorkflow(wf);
    await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    // Not valid UTF-8.
    final bad = await client.post('127.0.0.1', server.boundPort, '/webhook/notify');
    bad.add([0xff, 0xfe, 0xfd]);
    expect((await bad.close()).statusCode, 400);

    final ok = await client.post('127.0.0.1', server.boundPort, '/webhook/notify');
    ok.headers.contentType = ContentType.json;
    ok.write(jsonEncode({'title': 'Still here'}));
    expect((await ok.close()).statusCode, 200);
  });

  test('a web page may not call a webhook that has no key', () async {
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final server = WebhookServer(repository: repository, runner: runner, port: 0);
    final wf = templates.firstWhere((t) => t.title == 'Webhook to notification').build()..active = true;
    await repository.saveWorkflow(wf);
    await server.start();
    addTearDown(server.stop);

    final request = await HttpClient().post('127.0.0.1', server.boundPort, '/webhook/notify');
    request.headers.set('Origin', 'https://evil.example');
    request.write('{}');
    expect((await request.close()).statusCode, 403);
  });
}
