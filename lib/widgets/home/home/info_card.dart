import "package:auto_size_text/auto_size_text.dart";
import "package:flow/theme/theme.dart";
import "package:flow/widgets/general/surface.dart";
import "package:flutter/cupertino.dart";

class InfoCard extends StatelessWidget {
  final String title;
  final String value;

  final Widget? trailing;

  final AutoSizeGroup? autoSizeGroup;

  const InfoCard({
    super.key,
    required this.title,
    required this.value,
    this.trailing,
    this.autoSizeGroup,
  });

  @override
  Widget build(BuildContext context) {
    return Surface(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      builder: (BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: 16.0,
          vertical: 12.0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: context.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Flexible(
                  child: AutoSizeText(
                    value,
                    style: context.textTheme.displaySmall,
                    maxLines: 1,
                    group: autoSizeGroup,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8.0),
                  trailing!,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
