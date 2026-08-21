const layers = [
  { name: "NSManagedObjectContext", hint: "Your app talks only to Core Data" },
  { name: "NSPersistentStoreCoordinator", hint: "Apple Core Data or FreeCoreData on GNUstep" },
  { name: "ODataIncrementalStore", hint: "libobjc2 · executeRequest:withContext:error: · obtainPermanentIDsForObjects:" },
  { name: "OData v4 HTTP", hint: "$filter $expand $orderby POST PATCH DELETE" },
];

export function StackDiagram() {
  return (
    <ol className="space-y-2">
      {layers.map((layer, i) => (
        <li key={layer.name} className="rounded-lg bg-surface px-4 py-3 shadow-[var(--shadow-border)]">
          <p className="font-mono text-sm text-fg">
            <span className="mr-3 font-mono text-[0.6875rem] text-subtle">{String(i + 1).padStart(2, "0")}</span>
            {layer.name}
          </p>
          <p className="mt-1 pl-8 text-xs text-muted">{layer.hint}</p>
        </li>
      ))}
    </ol>
  );
}
