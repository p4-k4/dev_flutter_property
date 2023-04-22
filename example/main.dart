import 'dart:async';
import 'package:flutter/material.dart';
import 'package:property/property.dart';
import 'package:fpdart/fpdart.dart';

final counterA = Property<int>(() => const Option.none());

class Home extends StatelessWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Property Example')),
      body: Center(
        child: Column(
          children: [
            counterA.widget(
              fallback: const Text('Fallbackk'),
              onSome: (v) => Text(v.toString()),
              onNone: () => const Text('None'),
            ),
            ElevatedButton(
              child: const Text('++'),
              onPressed: () => counterA.update(
                ifSome: (v) => Some(v + 1),
                ifNone: () => const Some(0),
              ),
            ),
            ElevatedButton(
              child: const Text('nav'),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (c) => const Page1()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<int> incFuture(int value) =>
    Future.delayed(const Duration(seconds: 0), () => value + 1);

class Page1 extends StatelessWidget {
  const Page1({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Page 2')),
      body: ElevatedButton(
          onPressed: () => Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (c) => const Home())),
          child: const Text('Home')),
    );
  }
}
