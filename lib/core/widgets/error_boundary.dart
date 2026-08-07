import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(Object error, StackTrace? stack)? errorBuilder;
  final VoidCallback? onRetry;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
    this.onRetry,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stack;

  void _retry() {
    setState(() {
      _error = null;
      _stack = null;
    });
    widget.onRetry?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(_error!, _stack);
      }
      return _DefaultErrorWidget(
        error: _error!,
        onRetry: _retry,
      );
    }

    return widget.child;
  }

  @override
  void didUpdateWidget(ErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child && _error != null) {
      _retry();
    }
  }
}

class _DefaultErrorWidget extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _DefaultErrorWidget({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(30),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.error.withAlpha(60)),
              ),
              child: Icon(Icons.error_outline, size: 34, color: AppColors.error),
            ),
            const SizedBox(height: 16),
            Text(
              '出错了',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.onScaffold(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.secondaryText(context)),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 38,
              child: ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber,
                  foregroundColor: AppColors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                  padding: EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('重试', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
