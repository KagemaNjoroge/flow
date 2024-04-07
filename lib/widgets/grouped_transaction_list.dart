import 'package:flow/entity/transaction.dart';
import 'package:flow/l10n/extensions.dart';
import 'package:flow/objectbox/actions.dart';
import 'package:flow/prefs.dart';
import 'package:flow/utils/utils.dart';
import 'package:flow/widgets/transaction_list_tile.dart';
import 'package:flutter/widgets.dart';
import 'package:moment_dart/moment_dart.dart';

class GroupedTransactionList extends StatelessWidget {
  final EdgeInsets listPadding;
  final EdgeInsets itemPadding;

  /// Expects [transactions] to be sorted from oldest to newest
  final Map<TimeRange, List<Transaction>> transactions;

  final Widget Function(TimeRange range, List<Transaction> transaction)
      headerBuilder;

  /// Divider to displayed between future/past transactions. How it's divided
  /// is based on [anchor]
  final Widget? futureDivider;

  /// Used to determine which transactions are considered future or past.
  ///
  /// For now, only [futureDivider] makes use of this
  final DateTime? anchor;

  /// When set to true, displays one side of transfer transactions as empty [Container]s
  final bool shouldCombineTransferIfNeeded;

  final ScrollController? controller;

  final Widget? header;

  const GroupedTransactionList({
    super.key,
    required this.transactions,
    required this.headerBuilder,
    this.controller,
    this.header,
    this.listPadding = const EdgeInsets.symmetric(vertical: 16.0),
    this.itemPadding = const EdgeInsets.symmetric(
      horizontal: 16.0,
      vertical: 4.0,
    ),
    this.shouldCombineTransferIfNeeded = false,
    this.futureDivider,
    this.anchor,
  });

  @override
  Widget build(BuildContext context) {
    final DateTime anchor = this.anchor ?? DateTime.now();

    final bool combineTransfers = shouldCombineTransferIfNeeded &&
        LocalPreferences().combineTransferTransactions.get();

    final Map<TimeRange, List<Transaction>> past = Map.fromEntries(transactions
        .entries
        .where((element) => element.key.from.isPastAnchored(anchor)));

    final Map<TimeRange, List<Transaction>> future = Map.fromEntries(
        transactions.entries
            .where((element) => !element.key.from.isPastAnchored(anchor)));

    final List<Object> flattened = [
      if (header != null) header!,
      for (final entry in future.entries) ...[
        headerBuilder(entry.key, entry.value),
        ...entry.value,
      ],
      if (futureDivider != null && past.isNotEmpty && future.isNotEmpty)
        futureDivider!,
      for (final entry in past.entries) ...[
        headerBuilder(entry.key, entry.value),
        ...entry.value,
      ],
    ];

    return ListView.builder(
      controller: controller,
      padding: listPadding.copyWith(bottom: listPadding.bottom),
      itemBuilder: (context, index) => switch (flattened[index]) {
        (Widget header) => Padding(
            padding: itemPadding.copyWith(top: index == 0 ? 8.0 : 24.0),
            child: header,
          ),
        (Transaction transaction) => TransactionListTile(
            combineTransfers: combineTransfers,
            transaction: transaction,
            padding: itemPadding,
            dismissibleKey: ValueKey(transaction.id),
            deleteFn: () => deleteTransaction(context, transaction),
          ),
        (_) => Container(),
      },
      itemCount: flattened.length,
    );
  }

  Future<void> deleteTransaction(
    BuildContext context,
    Transaction transaction,
  ) async {
    final String txnTitle =
        transaction.title ?? "transaction.fallbackTitle".t(context);

    final confirmation = await context.showConfirmDialog(
      isDeletionConfirmation: true,
      title: "general.delete.confirmName".t(context, txnTitle),
    );

    if (confirmation == true) {
      transaction.delete();
    }
  }
}
