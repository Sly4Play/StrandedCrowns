export type Phase = "Dawn" | "Day" | "Dusk" | "Night"
export type Profession = "Builder" | "Vagrant"
export type NpcState =
    "InCamp" | "HiredWalking" | "IdleAtTown" |
    "Working" | "ReturningToWalls" | "AtWalls" | "Toolless" |
    "Wandering"

export type GreedState = "Scanning" | "Pursuing" | "Stealing" | "Retreating" | "Despawned"

export type GroundCoin = {
    instance: BasePart,
    amount:   number,
    ownerId:  number,
    droppedAt: number,
    despawnAt: number,
}

export type NpcData = {
    id:         string,
    instance:   Model,
    profession: Profession,
    tool:       BasePart?,
    purse:      number,
    maxPurse:   number,
    state:      NpcState,
    campId:     number?,
}

export type TreeData = {
    id:       string,
    instance: Model,
    position: Vector3,
    isMarked: boolean,
    markerId: number?,
    markCost: number,
}

export type PortalData = {
    instance:    BasePart,
    position:    Vector3,
    activeGreed: { Model },
    quota:       number,
    spawned:     number,
}

export type GreedData = {
    id:       string,
    instance: Model,
    state:    GreedState,
    target:   any?,
    portalPos: Vector3,
}

return nil
