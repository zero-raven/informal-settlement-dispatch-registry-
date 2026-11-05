// Shared UI Components for Dispatcher App

import 'package:flutter/material.dart';
import 'dart:ui' show ImageFilter;
import 'design_system.dart';

/// A card with consistent styling and optional elevation
class DSCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final List<BoxShadow>? shadows;
  final BorderRadius? borderRadius;
  final Border? border;
  final VoidCallback? onTap;
  final bool isInteractive;

  const DSCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.color,
    this.shadows,
    this.borderRadius,
    this.border,
    this.onTap,
    this.isInteractive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = color ?? (isDark ? DSColors.surface1 : Colors.white);

    Widget card = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.lg),
        border: border ??
            Border.all(
              color: isDark ? DSColors.border : Colors.grey[300]!,
              width: 0.5,
            ),
        boxShadow: shadows ?? (DSElevation.level1 > 0 ? DSShadows.level1 : null),
      ),
      padding: padding ?? const EdgeInsets.all(DSSpacing.cardPadding),
      child: child,
    );

    if (onTap != null || isInteractive) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.lg),
          child: card,
        ),
      );
    }

    return card;
  }
}

/// A card with gradient background for emphasis
class DSGradientCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Gradient? gradient;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;

  const DSGradientCard({
    super.key,
    required this.child,
    this.padding,
    this.gradient,
    this.borderRadius,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveGradient = gradient ?? DSColors.primaryGradient;

    Widget card = Container(
      decoration: BoxDecoration(
        gradient: effectiveGradient,
        borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.lg),
        boxShadow: DSShadows.glowPrimary,
      ),
      padding: padding ?? const EdgeInsets.all(DSSpacing.cardPadding),
      child: child,
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.lg),
          child: card,
        ),
      );
    }

    return card;
  }
}

/// Status badge with consistent styling
class DSStatusBadge extends StatelessWidget {
  final String label;
  final DSStatusType type;
  final IconData? icon;
  final bool isCompact;

  const DSStatusBadge({
    super.key,
    required this.label,
    required this.type,
    this.icon,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final (bgColor, textColor, iconColor) = switch (type) {
      DSStatusType.success => (
          DSColors.successContainer,
          DSColors.success,
          DSColors.success,
        ),
      DSStatusType.warning => (
          DSColors.warningContainer,
          DSColors.warning,
          DSColors.warning,
        ),
      DSStatusType.error => (
          DSColors.errorContainer,
          DSColors.error,
          DSColors.error,
        ),
      DSStatusType.info => (
          DSColors.info.withOpacity( 0.2),
          DSColors.info,
          DSColors.info,
        ),
      DSStatusType.neutral => (
          DSColors.surface2,
          DSColors.textSecondary,
          DSColors.textTertiary,
        ),
      DSStatusType.primary => (
          DSColors.primaryContainer,
          DSColors.primary,
          DSColors.primary,
        ),
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? DSSpacing.sm : DSSpacing.md,
        vertical: isCompact ? DSSpacing.xs : DSSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(DSBorderRadius.full),
        border: Border.all(
          color: textColor.withOpacity( 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: isCompact ? 12 : 14, color: iconColor),
            SizedBox(width: isCompact ? DSSpacing.xs : DSSpacing.sm),
          ],
          Text(
            label,
            style: (isCompact ? DSTypography.labelSmall : DSTypography.labelMedium)
                .copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

enum DSStatusType { success, warning, error, info, neutral, primary }

/// Stat card for dashboard metrics
class DSStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? iconColor;
  final Color? bgColor;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final String? subtitle;
  final Widget? trailing;

  const DSStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.iconColor,
    this.bgColor,
    this.gradient,
    this.onTap,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveBgColor = bgColor ?? (isDark ? DSColors.surface1 : Colors.white);
    final effectiveIconColor = iconColor ?? DSColors.primary;

    Widget card = Container(
      padding: const EdgeInsets.all(DSSpacing.cardPadding),
      decoration: BoxDecoration(
        color: gradient == null ? effectiveBgColor : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(DSBorderRadius.lg),
        border: gradient == null
            ? Border.all(
                color: isDark ? DSColors.border : Colors.grey[300]!,
                width: 0.5,
              )
            : null,
        boxShadow: gradient != null ? DSShadows.level1 : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.sm),
                decoration: BoxDecoration(
                  color: effectiveIconColor.withOpacity( 0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(icon, color: effectiveIconColor, size: 22),
              ),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: DSSpacing.md),
          Text(
            value,
            style: DSTypography.headlineMedium.copyWith(
              fontWeight: FontWeight.w700,
              color: gradient != null ? DSColors.textOnPrimary : DSColors.textPrimary,
            ),
          ),
          const SizedBox(height: DSSpacing.xs),
          Text(
            label,
            style: DSTypography.bodySmall.copyWith(
              color: gradient != null
                  ? DSColors.textOnPrimary.withOpacity( 0.8)
                  : DSColors.textTertiary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: DSSpacing.xs),
            Text(
              subtitle!,
              style: DSTypography.labelSmall.copyWith(
                color: gradient != null
                    ? DSColors.textOnPrimary.withOpacity( 0.7)
                    : DSColors.info,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DSBorderRadius.lg),
          child: card,
        ),
      );
    }

    return card;
  }
}

/// Empty state widget
class DSEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool compact;

  const DSEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = compact ? DSSpacing.lg : DSSpacing.xxl;
    final iconSize = compact ? 32.0 : 48.0;
    final titleStyle = compact ? DSTypography.titleMedium : DSTypography.headlineSmall;
    final messageStyle = compact ? DSTypography.bodySmall : DSTypography.bodyMedium;
    final spacing = compact ? DSSpacing.md : DSSpacing.lg;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(compact ? DSSpacing.md : DSSpacing.lg),
              decoration: BoxDecoration(
                color: isDark ? DSColors.surface2 : Colors.grey[100],
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: iconSize,
                color: DSColors.textTertiary,
              ),
            ),
            SizedBox(height: spacing),
            Text(
              title,
              style: titleStyle.copyWith(
                color: DSColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: DSSpacing.xs),
            Text(
              message,
              style: messageStyle.copyWith(
                color: DSColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              SizedBox(height: spacing),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Loading state widget
class DSLoadingState extends StatelessWidget {
  final String? message;
  final double size;

  const DSLoadingState({
    super.key,
    this.message,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(DSColors.primary),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: DSSpacing.md),
            Text(
              message!,
              style: DSTypography.bodyMedium.copyWith(
                color: DSColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// Error state widget
class DSErrorState extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final bool compact;

  const DSErrorState({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.retryLabel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = compact ? DSSpacing.lg : DSSpacing.xxl;
    final iconSize = compact ? 32.0 : 48.0;
    final titleStyle = compact ? DSTypography.titleMedium : DSTypography.headlineSmall;
    final messageStyle = compact ? DSTypography.bodySmall : DSTypography.bodyMedium;
    final spacing = compact ? DSSpacing.md : DSSpacing.lg;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(compact ? DSSpacing.md : DSSpacing.lg),
              decoration: BoxDecoration(
                color: DSColors.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                size: iconSize,
                color: DSColors.error,
              ),
            ),
            SizedBox(height: spacing),
            Text(
              title,
              style: titleStyle.copyWith(
                color: DSColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: DSSpacing.xs),
            Text(
              message,
              style: messageStyle.copyWith(
                color: DSColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              SizedBox(height: spacing),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(retryLabel ?? 'Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Section header with optional action
class DSSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  final bool showDivider;

  const DSSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: DSTypography.titleLarge.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: DSSpacing.xs),
                    Text(
                      subtitle!,
                      style: DSTypography.bodySmall.copyWith(
                        color: DSColors.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null) action!,
          ],
        ),
        if (showDivider) ...[
          const SizedBox(height: DSSpacing.sm),
          Divider(
            color: DSColors.divider,
            thickness: 0.5,
            height: 1,
          ),
        ],
      ],
    );
  }
}

/// Animated counter for stats
class DSAnimatedCounter extends StatefulWidget {
  final int targetValue;
  final Duration duration;
  final TextStyle? style;
  final String? prefix;
  final String? suffix;

  const DSAnimatedCounter({
    super.key,
    required this.targetValue,
    this.duration = const Duration(milliseconds: 1500),
    this.style,
    this.prefix,
    this.suffix,
  });

  @override
  State<DSAnimatedCounter> createState() => _DSAnimatedCounterState();
}

class _DSAnimatedCounterState extends State<DSAnimatedCounter>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<int> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );
    _animation = IntTween(begin: 0, end: widget.targetValue).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return RichText(
          text: TextSpan(
            style: widget.style ??
                DSTypography.headlineMedium.copyWith(fontWeight: FontWeight.w700),
            children: [
              if (widget.prefix != null)
                TextSpan(text: widget.prefix),
              TextSpan(text: _animation.value.toString()),
              if (widget.suffix != null)
                TextSpan(text: widget.suffix),
            ],
          ),
        );
      },
    );
  }
}

/// Shimmer loading placeholder
class DSShimmerPlaceholder extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const DSShimmerPlaceholder({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
  });

  const DSShimmerPlaceholder.rectangular({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
  });

  const DSShimmerPlaceholder.circular({
    super.key,
    required double size,
    this.borderRadius,
  }) : width = size, height = size;

  @override
  State<DSShimmerPlaceholder> createState() => _DSShimmerPlaceholderState();
}

class _DSShimmerPlaceholderState extends State<DSShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: -1, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? DSColors.surface2 : Colors.grey[300]!;
    final highlightColor = isDark ? DSColors.surface3 : Colors.grey[200]!;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius ?? BorderRadius.circular(DSBorderRadius.md),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                baseColor,
                highlightColor,
                baseColor,
              ],
              stops: [
                (_animation.value - 0.3).clamp(0.0, 1.0),
                _animation.value.clamp(0.0, 1.0),
                (_animation.value + 0.3).clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Skeleton loader for lists
class DSSkeletonList extends StatelessWidget {
  final int itemCount;
  final double itemHeight;
  final EdgeInsetsGeometry? padding;

  const DSSkeletonList({
    super.key,
    this.itemCount = 5,
    this.itemHeight = 80,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding ?? const EdgeInsets.all(DSSpacing.screenPadding),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: DSSpacing.sm),
      itemBuilder: (_, __) => DSShimmerPlaceholder.rectangular(
        width: double.infinity,
        height: itemHeight,
        borderRadius: BorderRadius.circular(DSBorderRadius.lg),
      ),
    );
  }
}

/// Action button row with consistent spacing
class DSActionRow extends StatelessWidget {
  final List<Widget> actions;
  final WrapAlignment alignment;
  final double spacing;

  const DSActionRow({
    super.key,
    required this.actions,
    this.alignment = WrapAlignment.center,
    this.spacing = DSSpacing.md,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: alignment,
      spacing: spacing,
      runSpacing: DSSpacing.sm,
      children: actions,
    );
  }
}

/// Primary action button
class DSPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool isExpanded;
  final double? width;

  const DSPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.isExpanded = true,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: isExpanded ? double.infinity : width,
      child: FilledButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(DSColors.textOnPrimary),
                ),
              )
            : (icon != null ? Icon(icon, size: 20) : const SizedBox.shrink()),
        label: Text(label),
        iconAlignment: iconAlignment,
      ),
    );
  }

  IconAlignment get iconAlignment => icon != null && !isLoading ? IconAlignment.start : IconAlignment.end;
}

/// Secondary action button
class DSSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isExpanded;
  final double? width;

  const DSSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isExpanded = true,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: isExpanded ? double.infinity : width,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon != null ? Icon(icon, size: 20) : const SizedBox.shrink(),
        label: Text(label),
      ),
    );
  }
}

/// Glass overlay for modals (per user preference: only modal glass-overlay)
class DSGlassOverlay extends StatelessWidget {
  final Widget child;
  final BorderRadius? borderRadius;

  const DSGlassOverlay({
    super.key,
    required this.child,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.xl),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: DSColors.surface1.withOpacity( 0.8),
            borderRadius: borderRadius ?? BorderRadius.circular(DSBorderRadius.xl),
            border: Border.all(
              color: DSColors.border.withOpacity( 0.5),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Hero section for dashboard
class DSHeroSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Gradient? gradient;

  const DSHeroSection({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DSSpacing.xl),
      decoration: BoxDecoration(
        gradient: gradient ?? DSColors.heroGradient,
        borderRadius: BorderRadius.circular(DSBorderRadius.xl),
        border: Border.all(
          color: DSColors.primary.withOpacity( 0.1),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: DSTypography.displaySmall.copyWith(
                    fontWeight: FontWeight.w700,
                    color: DSColors.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: DSSpacing.sm),
                Text(
                  subtitle,
                  style: DSTypography.bodyLarge.copyWith(
                    color: DSColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A styled dialog wrapper
class DSDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const DSDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      backgroundColor: isDark ? DSColors.surface1 : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DSBorderRadius.xl),
      ),
      title: Text(
        title,
        style: DSTypography.titleLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      content: content,
      actions: actions,
      actionsPadding: const EdgeInsets.fromLTRB(
        DSSpacing.md,
        0,
        DSSpacing.md,
        DSSpacing.md,
      ),
      buttonPadding: EdgeInsets.zero,
    );
  }
}