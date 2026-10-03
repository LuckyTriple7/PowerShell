---
name: vserv01-ressourcen
description: Ausführlicher Ressourcen-Check des Servers vserv01 – CPU, RAM, Swap, Platten, größte Container und Stacks, fehlgeschlagene Dienste, Journal-Fehler, Docker-Speicher. Nutzen bei Fragen nach Auslastung oder "was frisst Speicher".
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring, ressourcen]
    category: devops
---

# vserv01: Ressourcen

Nur Live-Daten, nichts erfinden, keine Websuche, Deutsch. Genau diese 5 Werkzeugaufrufe, keine weiteren und keine Wiederholungen:

1. monitor server_overview
2. monitor container_stats mit sort_by="ram", group_by_stack=true, limit=10
3. monitor container_stats mit sort_by="cpu", limit=8
4. monitor failed_services
5. monitor maintenance_status mit section="docker"

Verboten: alle uptime_kuma-Werkzeuge. Liefert ein Aufruf einen Fehler, schreibe für diesen Abschnitt "nicht verfügbar" und mache weiter.

Gib die Antwort GENAU EINMAL aus, ohne Text davor oder danach, mit je einer Leerzeile zwischen den Abschnitten:

🖥️ **vserv01 – Ressourcen**

⚙️ **System**
CPU: <Auslastung> %, Load <1/5/15 min> bei <Kerne> Kernen
RAM: <belegt>/<gesamt> (<Prozent> %), Swap <belegt>/<gesamt>
Platten: <je Mountpoint "Pfad Prozent % (frei X)">
Laufzeit: <Uptime>, Neustart nötig: <ja – Grund / nein>

📦 **Größte Stacks (RAM)**
<je Stack eine Zeile: Name – RAM, CPU; höchstens 10>

🔥 **CPU-Spitzenreiter**
<je Container eine Zeile: Name – CPU %; nur Container über 1 %, sonst "alles ruhig">

🧹 **Docker-Speicher**
<Images, Volumes, Build-Cache mit Größe und freigebbar; Warnung, falls vorhanden>

🚨 **Probleme**
<fehlgeschlagene Dienste, Container mit Problemen, häufigste Journal-Fehler (höchstens 5); sonst "keine">

✅ **To-do**
<nur Befehle, die in den Werkzeug-Antworten stehen, als root auf vserv01; sonst "nichts zu tun">
