import 'dart:convert';
import 'dart:io';

import 'package:codexter/mcp/tools/tool_bundle.dart';
import 'package:codexter/mcp/tools/tool_context.dart';
import 'package:codexter/models/downstream_mcp_entry.dart';
import 'package:codexter/models/global_config.dart';
import 'package:codexter/models/workspace.dart';
import 'package:codexter/services/capability_runtime.dart';
import 'package:codexter/services/computer_use_tools.dart';
import 'package:codexter/services/process_session_manager.dart';
import 'package:codexter/stores/log_store.dart';
import 'package:codexter/utils/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Computer Use 内置配置和工具定义保持完整', () {
    final entry = DownstreamMcpEntry.builtinComputerUse(enabled: true);
    expect(entry.name, computerUseMcpName);
    expect(entry.displayName, computerUseMcpDisplayName);
    expect(entry.isBuiltinComputerUse, isTrue);
    expect(entry.enabled, isTrue);
    expect(GlobalConfig().computerUseEnabled, isFalse);
    expect(computerUseToolDefinitions.map((tool) => tool['name']).toSet(), {
      'list_windows',
      'get_window',
      'list_apps',
      'launch_app',
      'get_window_state',
      'click',
      'press_key',
      'type_text',
      'scroll',
      'set_value',
      'drag',
      'perform_secondary_action',
      'activate_window',
      'end_turn',
    });
  });

  test('下游 MCP 工具区分只读发现与可能写入的调用', () async {
    final temp = await Directory.systemTemp.createTemp('codex_downstream_annotations_');
    final processManager = ProcessSessionManager();
    final capabilities = CapabilityRuntime();
    final logStore = LogStore();
    final now = DateTime.now();

    try {
      final registry = ToolBundle.build(
        ToolContext(
          workspace: Workspace(
            uuid: '11111111-1111-4111-8111-111111111113',
            name: 'downstream-annotations-test',
            projectRoot: temp.path,
            createdAt: now,
            lastActiveAt: now,
          ),
          pathGuard: PathGuard(temp.path),
          processManager: processManager,
          capabilities: capabilities,
          logStore: logStore,
        ),
      );
      // 检查 tools/list 实际使用的序列化结果，而不是只检查内部常量。
      final schemas = {for (final schema in registry.listSchemas()) schema.name: schema.toJson()};
      expect(schemas['mcp_tools']!['annotations'], {
        'readOnlyHint': true,
        'destructiveHint': false,
        'openWorldHint': true,
      });
      expect(schemas['mcp_call']!['annotations'], {
        'readOnlyHint': false,
        'destructiveHint': true,
        'openWorldHint': true,
      });
      for (final name in ['apply_patch', 'exec_command', 'write_stdin']) {
        expect((schemas[name]!['annotations'] as Map)['readOnlyHint'], isFalse, reason: name);
      }
    } finally {
      await capabilities.shutdown();
      capabilities.dispose();
      await processManager.shutdown();
      processManager.dispose();
      logStore.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('reconnect fails explicitly when downstream MCP is not active', () async {
    final capabilities = CapabilityRuntime();
    try {
      await expectLater(
        capabilities.reconnect('missing'),
        throwsA(
          isA<StateError>().having((error) => error.message, 'message', 'MCP 服务 missing 未启用或不存在'),
        ),
      );
    } finally {
      await capabilities.shutdown();
      capabilities.dispose();
    }
  });

  test('mcp_call preserves rich content and keeps required text output concise', () async {
    final temp = await Directory.systemTemp.createTemp('codex_downstream_tools_');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final processManager = ProcessSessionManager();
    final capabilities = CapabilityRuntime();
    final logStore = LogStore();
    String? receivedContentType;

    final serverTask = server.forEach((request) async {
      receivedContentType = request.headers.value(HttpHeaders.contentTypeHeader);
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final method = '${payload['method'] ?? ''}';
      final result = switch (method) {
        'initialize' => {
          'protocolVersion': '2025-06-18',
          'serverInfo': {'name': 'mock-rich-mcp', 'version': '1.0.0'},
          'capabilities': <String, dynamic>{},
        },
        'tools/list' => {
          'tools': [
            {
              'name': 'capture',
              'description': 'Return a mock image',
              'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
            },
          ],
        },
        'tools/call' => {
          'content': [
            {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
          ],
          'structuredContent': {'kind': 'screenshot'},
        },
        _ => <String, dynamic>{},
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          if (payload['id'] != null) 'id': payload['id'],
          'result': result,
        }),
      );
      await request.response.close();
    });

    final entry = DownstreamMcpEntry(
      name: 'mock-rich',
      transportJson: DownstreamMcpEntry.buildUrlJson(url: 'http://127.0.0.1:${server.port}/mcp'),
      source: 'manual',
    );
    final now = DateTime.now();
    final workspace = Workspace(
      uuid: '11111111-1111-4111-8111-111111111112',
      name: 'downstream-test',
      projectRoot: temp.path,
      createdAt: now,
      lastActiveAt: now,
    );

    try {
      await capabilities.syncMcps([entry]);
      expect(receivedContentType, 'application/json');
      final context = ToolContext(
        workspace: workspace,
        pathGuard: PathGuard(temp.path),
        processManager: processManager,
        capabilities: capabilities,
        logStore: logStore,
      );
      final registry = ToolBundle.build(context);

      final listing = await registry.invoke('mcp_tools', {'purpose': '核对下游工具列表'});
      expect(listing.isError, isFalse);
      expect(listing.structuredContent!['text'], startsWith('=== ${entry.name} [connected]'));
      final grouped = listing.structuredContent!['tools'] as Map;
      expect(grouped.keys, [entry.name]);
      expect((grouped[entry.name] as List).single['name'], 'capture');

      final result = await registry.invoke('mcp_call', {
        'purpose': '读取下游截图',
        'server': entry.name,
        'tool': 'capture',
        'arguments': <String, dynamic>{},
      });

      expect(result.isError, isFalse);
      expect(result.content, hasLength(1));
      expect(result.content.single['type'], 'image');
      expect(result.content.single['data'], 'AAAA');
      expect(result.structuredContent?['kind'], 'screenshot');
      expect(result.structuredContent?['text'], '[image: image/png]');
      expect('${result.structuredContent?['text']}', isNot(contains('AAAA')));
    } finally {
      await capabilities.shutdown();
      capabilities.dispose();
      await processManager.shutdown();
      processManager.dispose();
      logStore.dispose();
      await server.close(force: true);
      await serverTask;
      await temp.delete(recursive: true);
    }
  });
}
