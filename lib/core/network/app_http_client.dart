import 'package:dio/dio.dart';

final class AppHttpClient {
  static Dio create({BaseOptions? options}) => Dio(options ?? BaseOptions());
}
