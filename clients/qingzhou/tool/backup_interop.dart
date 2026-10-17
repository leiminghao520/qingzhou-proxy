import 'dart:io';
import 'package:qingzhou/domain/backup.dart';
import 'package:qingzhou/domain/catalog.dart';
import 'package:qingzhou/domain/importer.dart';
Future<void> main(List<String> args)async{
 final catalog=Catalog.empty();final candidate=Importer.node('trojan://fixture-only@example.com:443#Dart测试');
 catalog.state['nodes']=[candidate.node];catalog.state['selectedPolicy']=reference('node',candidate.node['id'] as String);
 await File(args.single).writeAsBytes(await Backup.encrypt(Snapshot(catalog,candidate.credentials),'fixture-password'));
}
