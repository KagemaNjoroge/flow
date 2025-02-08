import "dart:developer";
import "dart:io";
import "dart:math" as math;

import "package:flow/data/exchange_rates.dart";
import "package:flow/data/flow_analytics.dart";
import "package:flow/data/memo.dart";
import "package:flow/data/money.dart";
import "package:flow/data/money_flow.dart";
import "package:flow/data/prefs/frecency_group.dart";
import "package:flow/data/transactions_filter.dart";
import "package:flow/entity/account.dart";
import "package:flow/entity/backup_entry.dart";
import "package:flow/entity/category.dart";
import "package:flow/entity/transaction.dart";
import "package:flow/entity/transaction/extensions/base.dart";
import "package:flow/entity/transaction/extensions/default/transfer.dart";
import "package:flow/l10n/extensions.dart";
import "package:flow/objectbox.dart";
import "package:flow/objectbox/objectbox.g.dart";
import "package:flow/prefs.dart";
import "package:flow/services/exchange_rates.dart";
import "package:flow/services/transactions.dart";
import "package:flow/utils/utils.dart";
import "package:fuzzywuzzy/fuzzywuzzy.dart";
import "package:moment_dart/moment_dart.dart";
import "package:uuid/uuid.dart";

typedef RelevanceScoredTitle = ({String title, double relevancy});

extension MainActions on ObjectBox {
  /// Returns the grand total of all accounts in primary currency in the primary currency
  Money getPrimaryCurrencyGrandTotal() {
    final String primaryCurrency = LocalPreferences().getPrimaryCurrency();

    final Query<Account> accountsQuery = box<Account>()
        .query(Account_.excludeFromTotalBalance
            .notEquals(true)
            .and(Account_.currency.equals(primaryCurrency)))
        .build();

    final List<Account> accounts = accountsQuery.find();

    accountsQuery.close();

    return accounts.map((e) => e.balance).fold(Money(0, primaryCurrency),
        (previousValue, element) => previousValue + element);
  }

  /// Returns the grand total of all accounts (including non-primary currency accounts) in the primary currency
  Future<Money?> getGrandTotal() async {
    final String primaryCurrency = LocalPreferences().getPrimaryCurrency();

    final Condition<Account> query = Account_.excludeFromTotalBalance
        .isNull()
        .or(Account_.excludeFromTotalBalance.notEquals(true))
        .and(Account_.archived.isNull().or(Account_.archived.notEquals(true)));

    final Query<Account> accountsQuery = box<Account>().query(query).build();

    final List<Account> accounts = accountsQuery.find();

    accountsQuery.close();

    Money total = accounts
        .where((account) => account.currency == primaryCurrency)
        .fold<Money>(
          Money(0, primaryCurrency),
          (previousValue, element) => previousValue + element.balance,
        );

    final List<Account> nonPrimaryCurrencyAccounts = accounts
        .where((account) => account.currency != primaryCurrency)
        .toList();

    final ExchangeRates? rates =
        await ExchangeRatesService().tryFetchRates(primaryCurrency);

    if (rates == null) return null;

    for (final Account account in nonPrimaryCurrencyAccounts) {
      final Money converted = account.balance.convert(primaryCurrency, rates);

      total += converted;
    }

    return total;
  }

  List<Account> getAccounts([bool sortByFrecency = true]) {
    final List<Account> accounts = box<Account>().getAll();

    accounts.removeWhere((account) => account.archived == true);

    if (sortByFrecency) {
      final FrecencyGroup frecencyGroup = FrecencyGroup(accounts
          .map((account) =>
              LocalPreferences().getFrecencyData("account", account.uuid))
          .nonNulls
          .toList());

      accounts.sort((a, b) => frecencyGroup
          .getScore(b.uuid)
          .compareTo(frecencyGroup.getScore(a.uuid)));
    }

    return accounts;
  }

  List<Category> getCategories([bool sortByFrecency = true]) {
    final List<Category> categories = box<Category>().getAll();

    if (sortByFrecency) {
      final FrecencyGroup frecencyGroup = FrecencyGroup(categories
          .map((category) =>
              LocalPreferences().getFrecencyData("category", category.uuid))
          .nonNulls
          .toList());

      categories.sort((a, b) => frecencyGroup
          .getScore(b.uuid)
          .compareTo(frecencyGroup.getScore(a.uuid)));
    }

    return categories;
  }

  Future<void> updateAccountOrderList({
    List<Account>? accounts,
    bool ignoreIfNoUnsetValue = false,
  }) async {
    accounts ??= await ObjectBox().box<Account>().getAllAsync();

    if (ignoreIfNoUnsetValue &&
        !accounts.any((element) => element.sortOrder < 0)) {
      return;
    }

    for (final e in accounts.indexed) {
      accounts[e.$1].sortOrder = e.$1;
    }

    await ObjectBox().box<Account>().putManyAsync(accounts);
  }

  /// Returns all non-pending transactions in given [range]
  Future<List<Transaction>> transcationsByRange(TimeRange range) async {
    final TransactionFilter filter =
        TransactionFilter(range: range, isPending: false);

    final List<Transaction> transactions =
        await TransactionsService().findMany(filter);

    return transactions;
  }

  Future<Map<T, MoneyFlow<K>>> flowBy<T, K>(
      List<Transaction> transactions,
      T? Function(Transaction t) keyBy,
      K Function(Transaction t)? associateBy) async {
    final Map<T, MoneyFlow<K>> flow = {};

    for (final transaction in transactions) {
      final T? key = keyBy(transaction);

      if (key == null) continue;

      final K? associatedData = associateBy?.call(transaction);

      flow[key] ??= MoneyFlow<K>(associatedData: associatedData);
      flow[key]!.add(transaction.money);
    }

    return flow;
  }

  /// Returns a map of category uuid -> [MoneyFlow]
  Future<FlowAnalytics<Category?>> flowByCategories({
    required TimeRange range,
    bool ignoreTransfers = true,
  }) async {
    final List<Transaction> transactions = await transcationsByRange(range);

    final flow = await flowBy(transactions, (t) {
      if (ignoreTransfers && t.isTransfer) return null;

      return t.category.target?.uuid ?? Namespace.nil.value;
    }, (t) => t.category.target);

    return FlowAnalytics(flow: flow, range: range);
  }

  /// Returns a map of category uuid -> [MoneyFlow]
  Future<FlowAnalytics<Account>> flowByAccounts({
    required TimeRange range,
    bool ignoreTransfers = true,
  }) async {
    final List<Transaction> transactions = await transcationsByRange(range);

    final Map<String, MoneyFlow<Account>> flow =
        await flowBy(transactions, (t) {
      if (ignoreTransfers && t.isTransfer) return null;

      return t.account.target?.uuid ?? Namespace.nil.value;
    }, (t) => t.account.target!);

    assert(
      !flow.containsKey(Namespace.nil.value),
      "There is no way you've managed to make a transaction without an account",
    );

    return FlowAnalytics(flow: flow, range: range);
  }

  Future<List<RelevanceScoredTitle>> transactionTitleSuggestions({
    String? currentInput,
    int? accountId,
    int? categoryId,
    TransactionType? type,
    int? limit,
  }) async {
    final TransactionFilter filter = TransactionFilter(
        searchData: TransactionSearchData(
      includeDescription: false,
      keyword: currentInput?.trim() ?? "",
    ));

    final List<Transaction> transactions = await TransactionsService()
        .findMany(filter)
        .then((value) => value.where((element) {
              if (element.title?.trim().isNotEmpty != true) {
                return false;
              }
              if (type != TransactionType.transfer && element.isTransfer) {
                return false;
              }

              return true;
            }).toList())
        .catchError(
      (error) {
        log("Failed to fetch transactions for title suggestions: $error");
        return <Transaction>[];
      },
    );

    final List<RelevanceScoredTitle> relevanceCalculatedList = transactions
        .map((e) => (
              title: e.title,
              relevancy: e.titleSuggestionScore(
                accountId: accountId,
                categoryId: categoryId,
                transactionType: type,
              )
            ))
        .cast<RelevanceScoredTitle>()
        .toList();

    relevanceCalculatedList.sort((a, b) => b.relevancy.compareTo(a.relevancy));

    final List<RelevanceScoredTitle> scoredTitles =
        _mergeTitleRelevancy(relevanceCalculatedList);

    scoredTitles.sort((a, b) => b.relevancy.compareTo(a.relevancy));

    return scoredTitles.sublist(
      0,
      limit == null ? null : math.min(limit, scoredTitles.length),
    );
  }

  /// Removes duplicates from the iterable based on the keyExtractor function.
  List<RelevanceScoredTitle> _mergeTitleRelevancy(
    List<RelevanceScoredTitle> scores,
  ) {
    final List<List<RelevanceScoredTitle>> grouped =
        scores.groupBy((relevance) => relevance.title).values.toList();

    return grouped.map(
      (items) {
        final double sum = items
            .map((x) => x.relevancy)
            .fold<double>(0, (value, element) => value + element);

        final double average = sum / items.length;

        /// If an item occurs multiple times, its relevancy is increased
        final double weight = 1 + (items.length * 0.025);

        return (
          title: items.first.title,
          relevancy: average * weight,
        );
      },
    ).toList();
  }
}

extension TransactionActions on Transaction {
  /// Base score is 10.0
  ///
  /// * If [query] is exactly same as [title], score is base + 100.0 (110.0)
  /// * If [accountId] matches, score is increased by 25%
  /// * If [transactionType] matches, score is increased by 75%
  /// * If [categoryId] matches, score is increased by 275%
  ///
  /// **Max score**: 412.5
  /// **Query only max score**: 110.0
  ///
  /// Recommended to set [fuzzyPartial] to false when using for filtering purposes
  double titleSuggestionScore({
    String? query,
    int? accountId,
    int? categoryId,
    TransactionType? transactionType,
    bool fuzzyPartial = true,
    bool caseSensitive = false,
  }) {
    double score = 10.0;

    final String? normalizedTitle =
        caseSensitive ? title?.trim() : title?.trim().toLowerCase();

    if (query?.trim().isNotEmpty == true && normalizedTitle != null) {
      score += fuzzyPartial
          ? partialRatio(query!, normalizedTitle).toDouble()
          : ratio(query!, normalizedTitle).toDouble();
    }

    double multipler = 1.0;

    if (account.targetId == accountId) {
      multipler += 0.25;
    }

    if (transactionType != null && transactionType == type) {
      multipler += 0.75;
    }

    if (category.targetId == categoryId) {
      multipler += 2.75;
    }

    return score * multipler;
  }

  /// When user makes a transfer, it actually creates two transactions.
  ///
  /// 1. The main one (amount is positive)
  /// 2. The counter one (amount is negative)
  ///
  /// When editting transfer, everything should be applied to both
  /// transactions for consistency.
  Transaction? findTransferOriginalOrThis() {
    if (!isTransfer) return this;

    final Transfer transfer = extensions.transfer!;

    if (amount.isNegative) return this;

    final Query<Transaction> query = ObjectBox()
        .box<Transaction>()
        .query(Transaction_.uuid
            .equals(transfer.relatedTransactionUuid ?? Namespace.nil.value))
        .build();

    try {
      return query.findFirst();
    } catch (e) {
      return this;
    } finally {
      query.close();
    }
  }

  bool delete() {
    if (isTransfer) {
      final Transfer? transfer = extensions.transfer;

      if (transfer == null) {
        log("Couldn't delete transfer transaction properly due to missing transfer data");
      } else {
        final TransactionFilter filter = TransactionFilter(
            uuids: [transfer.relatedTransactionUuid ?? Namespace.nil.value]);

        final Transaction? relatedTransaction =
            TransactionsService().findFirstSync(filter);

        try {
          final bool removedRelated = ObjectBox()
              .box<Transaction>()
              .remove(relatedTransaction?.id ?? -1);

          if (!removedRelated) {
            throw Exception("Failed to remove related transaction");
          }
        } catch (e) {
          log("Couldn't delete transfer transaction properly due to: $e");
        }
      }
    }

    return TransactionsService().deleteSync(id);
  }

  bool confirm([bool confirm = true, bool updateTransactionDate = true]) {
    try {
      if (isTransfer) {
        final Transfer? transfer = extensions.transfer;

        if (transfer == null) {
          log("Couldn't delete transfer transaction properly due to missing transfer data");
        } else {
          final Query<Transaction> relatedTransactionQuery = ObjectBox()
              .box<Transaction>()
              .query(Transaction_.uuid.equals(
                  transfer.relatedTransactionUuid ?? Namespace.nil.value))
              .build();

          final Transaction? relatedTransaction =
              relatedTransactionQuery.findFirst();

          relatedTransactionQuery.close();

          try {
            if (relatedTransaction == null) {
              throw Exception("Related transaction not found");
            }

            relatedTransaction.isPending = !confirm;
            if (updateTransactionDate && isPending != true) {
              relatedTransaction.transactionDate = Moment.now();
            }
            ObjectBox()
                .box<Transaction>()
                .put(relatedTransaction, mode: PutMode.update);
          } catch (e) {
            log("Couldn't delete transfer transaction properly due to: $e");
          }
        }
      }

      isPending = !confirm;
      if (updateTransactionDate && isPending != true) {
        transactionDate = Moment.now();
      }

      TransactionsService().updateOne(this);
      return true;
    } catch (e) {
      log("Failed to confirm transaction: $e");
      return false;
    }
  }

  /// Returns the ObjectBox ID for the newly created transaction
  int duplicate() {
    if (isTransfer) {
      throw Exception("Cannot duplicate transfer transactions");
    }

    final Transaction duplicate = Transaction(
      amount: amount,
      currency: currency,
      title: title,
      description: description,
      transactionDate: transactionDate,
      createdDate: Moment.now(),
      isPending: isPending,
      uuid: Uuid().v4(),
    )
      ..setCategory(category.target)
      ..setAccount(account.target);

    final List<TransactionExtension> filteredExtensions =
        extensions.data.where((ext) => ext is! Transfer).toList();

    if (filteredExtensions.isNotEmpty) {
      duplicate.addExtensions(filteredExtensions);
    }

    return TransactionsService().upsertOneSync(duplicate);
  }
}

extension AccountListActions on Iterable<Account> {
  Iterable<Account> get actives => where((account) => account.archived != true);
  Iterable<Account> get inactives =>
      where((account) => account.archived == true);
}

extension TransactionListActions on Iterable<Transaction> {
  Iterable<Transaction> get nonTransfers =>
      where((transaction) => !transaction.isTransfer);
  Iterable<Transaction> get transfers =>
      where((transaction) => transaction.isTransfer);
  Iterable<Transaction> get expenses =>
      where((transaction) => transaction.amount.isNegative);
  Iterable<Transaction> get incomes =>
      where((transaction) => transaction.amount > 0);
  Iterable<Transaction> get nonPending =>
      where((transaction) => transaction.isPending != true);

  /// Number of transactions that are rendered on the screen
  ///
  /// This depends on [LocalPreferences().combineTransferTransactions]
  /// and current list of transactions
  int get renderableCount =>
      length -
      (LocalPreferences().combineTransferTransactions.get()
          ? transfers.length ~/ 2
          : 0);

  double get incomeSumWithoutCurrency =>
      incomes.fold(0, (value, element) => value + element.amount);
  double get expenseSumWithoutCurrency =>
      expenses.fold(0, (value, element) => value + element.amount);
  double get sumWithoutCurrency =>
      fold(0, (value, element) => value + element.amount);

  Money get incomeSum => incomes.fold(
      Money(0.0, firstOrNull?.currency ?? "XXX"),
      (value, element) => value + element.money);
  Money get expenseSum => expenses.fold(
      Money(0.0, firstOrNull?.currency ?? "XXX"),
      (value, element) => value + element.money);
  Money get sum => fold(Money(0.0, firstOrNull?.currency ?? "XXX"),
      (value, element) => value + element.money);

  MoneyFlow get flow => MoneyFlow()
    ..addAll(
      map((transaction) => transaction.money),
    );

  /// If [mergeFutureTransactions] is set to true, transactions in future
  /// relative to [anchor] will be grouped into the same group
  Map<TimeRange, List<Transaction>> groupByDate({
    DateTime? anchor,
  }) =>
      groupByRange(
        rangeFn: (transaction) => DayTimeRange.fromDateTime(
          transaction.transactionDate,
        ),
        anchor: anchor,
      );

  Map<TimeRange, List<Transaction>> groupByRange({
    DateTime? anchor,
    required TimeRange Function(Transaction) rangeFn,
  }) {
    anchor ??= DateTime.now();

    final Map<TimeRange, List<Transaction>> value = {};

    for (final transaction in this) {
      final TimeRange range = rangeFn(transaction);

      value[range] ??= [];
      value[range]!.add(transaction);
    }

    return value;
  }

  List<Transaction> filter(List<bool Function(Transaction)> predicates) =>
      where((Transaction t) => predicates
          .map((predicate) => predicate(t))
          .every((element) => element)).toList();

  List<Transaction> search(TransactionSearchData? data) {
    if (data == null || data.normalizedKeyword == null) return toList();

    final matches = where(data.predicate).toList();

    if (data.mode == TransactionSearchMode.smart && matches.isEmpty) {
      return search(
          data.copyWithOptional(mode: TransactionSearchMode.substring));
    }

    return matches;
  }
}

extension AccountActions on Account {
  static Memoizer<String, String?>? accountNameToUuid;

  static String nameByUuid(String uuid) {
    accountNameToUuid ??= Memoizer(
      compute: _nameByUuid,
    );

    return accountNameToUuid!.get(uuid) ?? "???";
  }

  static String _nameByUuid(String uuid) {
    final query =
        ObjectBox().box<Account>().query(Account_.uuid.equals(uuid)).build();

    try {
      return query.findFirst()?.name ?? "???";
    } catch (e) {
      return "???";
    } finally {
      query.close();
    }
  }

  /// Creates a new transaction, and saves it
  ///
  /// Returns transaction id from [Box.put]
  int updateBalanceAndSave(
    double targetBalance, {
    String? title,
    DateTime? transactionDate,
  }) {
    final double delta = targetBalance -
        (transactionDate == null
            ? balance.amount
            : balanceAt(transactionDate).amount);

    return createAndSaveTransaction(
      amount: delta,
      title: title,
      transactionDate: transactionDate,
      subtype: TransactionSubtype.updateBalance,
    );
  }

  /// Returns object ids from `box.put`
  ///
  /// First transaction represents money going out of [this] account
  ///
  /// Second transaction represents money incoming to the target account
  (int from, int to) transferTo({
    String? title,
    String? description,
    required Account targetAccount,
    required double amount,
    DateTime? createdDate,
    DateTime? transactionDate,
    double? latitude,
    double? longitude,
    List<TransactionExtension>? extensions,
    bool? isPending,
  }) {
    if (amount <= 0) {
      return targetAccount.transferTo(
        targetAccount: this,
        amount: amount.abs(),
        title: title,
        description: description,
        createdDate: createdDate,
        transactionDate: transactionDate,
        latitude: latitude,
        longitude: longitude,
        extensions: extensions,
        isPending: isPending,
      );
    }

    final String fromTransactionUuid = const Uuid().v4();
    final String toTransactionUuid = const Uuid().v4();

    final Transfer transferData = Transfer(
      uuid: const Uuid().v4(),
      fromAccountUuid: uuid,
      toAccountUuid: targetAccount.uuid,
      relatedTransactionUuid: toTransactionUuid,
    );

    final String resolvedTitle = title ??
        "transaction.transfer.fromToTitle"
            .tr({"from": name, "to": targetAccount.name});

    final List<TransactionExtension> filteredExtensions =
        extensions?.where((ext) => ext is! Transfer).toList() ?? [];

    final int fromTransaction = createAndSaveTransaction(
      amount: -amount,
      title: resolvedTitle,
      description: description,
      extensions: [
        transferData,
        ...filteredExtensions,
      ],
      uuidOverride: fromTransactionUuid,
      createdDate: createdDate,
      transactionDate: transactionDate,
      isPending: isPending,
    );
    final int toTransaction = targetAccount.createAndSaveTransaction(
      amount: amount,
      title: resolvedTitle,
      description: description,
      extensions: [
        transferData.copyWith(relatedTransactionUuid: fromTransactionUuid),
        ...filteredExtensions,
      ],
      uuidOverride: toTransactionUuid,
      createdDate: createdDate,
      transactionDate: transactionDate,
      isPending: isPending,
    );

    return (fromTransaction, toTransaction);
  }

  /// Returns transaction id from [Box.put]
  int createAndSaveTransaction({
    required double amount,
    DateTime? transactionDate,
    DateTime? createdDate,
    String? title,
    String? description,
    Category? category,
    List<TransactionExtension>? extensions,
    String? uuidOverride,
    bool? isPending,
    TransactionSubtype? subtype,
  }) {
    final String uuid = uuidOverride ?? const Uuid().v4();

    Transaction value = Transaction(
      amount: amount,
      currency: currency,
      title: title,
      description: description,
      transactionDate: transactionDate,
      createdDate: createdDate,
      uuid: uuid,
      isPending: isPending ?? false,
      subtype: subtype?.value,
    )
      ..setCategory(category)
      ..setAccount(this);

    final List<TransactionExtension>? applicableExtensions = extensions
        ?.map((ext) {
          log("Adding extension to Transaction($uuidOverride): ${ext.runtimeType}(${ext.uuid})");
          log("Checking extension: ${ext.runtimeType}");

          if (ext.relatedTransactionUuid == null) {
            return ext..setRelatedTransactionUuid(uuid);
          }

          if (ext.key == Transfer.keyName) {
            // Transfer extension is handled separately
            return ext;
          }

          if (ext.relatedTransactionUuid == uuid) {
            return ext;
          }

          return null;
        })
        .nonNulls
        .toList();

    if (applicableExtensions != null && applicableExtensions.isNotEmpty) {
      value.addExtensions(applicableExtensions);
    }

    final int id = TransactionsService().upsertOneSync(value);

    try {
      LocalPreferences().updateFrecencyData("account", uuid);
      if (category != null) {
        LocalPreferences().updateFrecencyData("category", category.uuid);
      }
    } catch (e) {
      log("Failed to update frecency data for transaction ($id)");
    }

    return id;
  }
}

extension BackupEntryActions on BackupEntry {
  Future<bool> delete() async {
    try {
      final File file = File(filePath);

      if (await file.exists()) {
        await file.delete();
      }

      return ObjectBox().box<BackupEntry>().remove(id);
    } catch (e) {
      return false;
    }
  }
}
