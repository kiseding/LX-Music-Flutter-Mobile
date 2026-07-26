import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class LoadingWidget extends StatelessWidget {
  final String? hint;

  const LoadingWidget({super.key, this.hint});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 12),
            Text(
              hint!,
              style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
