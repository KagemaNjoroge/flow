import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flow/data/currencies.dart';
import 'package:flow/data/exchange_rates_set.dart';
import 'package:flow/prefs.dart';
import 'package:http/http.dart' as http;
import 'package:moment_dart/moment_dart.dart';

/// Uses endpoints from here:
class ExchangeRates {
  final DateTime date;
  final String baseCurrency;
  final Map<String, double> rates;

  const ExchangeRates({
    required this.date,
    required this.baseCurrency,
    required this.rates,
  });

  factory ExchangeRates.fromJson(
    String baseCurrency,
    Map<String, dynamic> json,
  ) {
    return ExchangeRates(
      date: DateTime.parse(json['date']),
      baseCurrency: baseCurrency,
      rates: Map<String, double>.from(json[baseCurrency.toLowerCase()]),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "date": date.format(payload: "yyyy-MM-dd"),
      "baseCurrency": baseCurrency,
      "rates": rates,
    };
  }

  static const ExchangeRatesSet _cache = ExchangeRatesSet({});

  static void updateCache(String baseCurrency, ExchangeRates exchangeRates) {
    _cache.set(baseCurrency, exchangeRates);

    try {
      unawaited(LocalPreferences().exchangeRatesCache.set(_cache));
    } catch (e) {
      log("Failed to update exchange rates cache", error: e);
    }
  }

  static ExchangeRates? getCachedRates(String baseCurrency) =>
      _cache.get(baseCurrency);

  static ExchangeRates? getPrimaryCurrencyRates() {
    return _cache.get(LocalPreferences().getPrimaryCurrency());
  }

  static Future<ExchangeRates> fetchRates(
    String baseCurrency, [
    DateTime? dateTime,
  ]) async {
    final String normalizedCurrency = baseCurrency.trim().toLowerCase();

    if (!isCurrencyCodeValid(normalizedCurrency)) {
      throw Exception("Invalid currency code: $baseCurrency");
    }

    final String dateParam =
        dateTime == null ? "latest" : dateTime.format(payload: "yyyy-MM-dd");

    Map<String, dynamic>? jsonResponse;

    try {
      final response = await http.get(Uri.parse(
          "https://$dateParam.currency-api.pages.dev/v1/currencies/$normalizedCurrency.json"));
      jsonResponse = jsonDecode(response.body);
    } catch (e) {
      log("Failed to fetch exchange rates from side source", error: e);
    }

    try {
      final response = await http.get(Uri.parse(
          "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@$dateParam/v1/currencies/$normalizedCurrency.json"));
      jsonResponse = jsonDecode(response.body);
    } catch (e) {
      log("Failed to fetch exchange rates from main source", error: e);
    }

    if (jsonResponse == null) {
      throw Exception("Failed to fetch exchange rates");
    }

    final exchangeRates =
        ExchangeRates.fromJson(normalizedCurrency, jsonResponse);
    _cache.set(baseCurrency, exchangeRates);
    return exchangeRates;
  }

  static Future<ExchangeRates?> tryFetchRates(
    String baseCurrency, [
    DateTime? dateTime,
  ]) async {
    try {
      final ExchangeRates exchangeRates =
          await fetchRates(baseCurrency, dateTime);
      return exchangeRates;
    } catch (e) {
      return _cache.get(baseCurrency);
    }
  }
}
