"use client";

import { useEffect, useState } from "react";
import * as fcl from "@onflow/fcl";
import "../lib/fclConfig";

type FlowUser = {
  addr?: string | null;
};

export function useFlowUser() {
  const [user, setUser] = useState<FlowUser | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = fcl.currentUser().subscribe((u: FlowUser | null) => {
      setUser(u);
      setLoading(false);
    });

    return () => {
      if (typeof unsubscribe === "function") {
        unsubscribe();
      }
    };
  }, []);

  const logIn = () => fcl.logIn();
  const logOut = () => fcl.unauthenticate();

  return { user, loading, logIn, logOut };
}

