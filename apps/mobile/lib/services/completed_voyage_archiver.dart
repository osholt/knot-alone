import '../domain/completed_voyage.dart';
import '../domain/imported_route.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_session.dart';
import 'voyage_summary_exporter.dart';

class CompletedVoyageArchiver {
  const CompletedVoyageArchiver({
    this.summaryExporter = const VoyageSummaryExporter(),
  });

  final VoyageSummaryExporter summaryExporter;

  CompletedVoyage create({
    required VoyageSession session,
    required Iterable<VoyageEvent> events,
    required DateTime archivedAt,
    ImportedRoute? plannedRoute,
  }) {
    final summary = summaryExporter.summarize(
      session,
      events,
      generatedAt: archivedAt,
    );
    return CompletedVoyage(
      voyageId: session.voyageId,
      voyageCode: session.voyageCode,
      voyageName: session.voyageName,
      localDisplayName: session.displayName,
      localRole: session.role,
      startedAt: summary.startedAt,
      endedAt: summary.endedAt ?? archivedAt,
      archivedAt: archivedAt,
      sailorCount: summary.sailorCount,
      eventCount: summary.eventCount,
      totalDistanceMeters: summary.totalDistanceMeters,
      markerSessions: [
        for (final marker in summary.markerSessions)
          CompletedMarkerSession(
            startedAt: marker.startedAt,
            endedAt: marker.endedAt,
            uniquePassCount: marker.uniquePassCount,
          ),
      ],
      plannedRoute: plannedRoute,
      traveledRoute: summaryExporter.traveledRoute(
        session,
        events,
        generatedAt: archivedAt,
      ),
    );
  }
}
