// Dark modern unified theme (UI/UX Pro Max: Dark Mode OLED)
// All surfaces: mapper, dispatcher, grievance — responsive
import 'package:flutter/material.dart';
final darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF020617), // background
  primaryColor: const Color(0xFF0F172A),            // primary
  cardColor: const Color(0xFF1E293B).withOpacity(0.6), // glass base
  textTheme: const TextTheme(
    displayLarge: TextStyle(fontFamily: 'FiraSans', color: Color(0xFFF8FAFC), fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontFamily: 'FiraSans', color: Color(0xFFF8FAFC)),
  ),
);
const glassDark = BoxDecoration(
  color: Color(0x331E293B), // muted glass
  borderRadius: BorderRadius.all(Radius.circular(16)),
  border: Border.all(color: Color(0xFF334155), width: 1),
  boxShadow: [BoxShadow(color: Color(0x3322C55E), blurRadius: 12, spreadRadius: 2)],
);
const gradientAccent = LinearGradient(colors: [Color(0xFF22C55E), Color(0xFF6EE7FF)]);
