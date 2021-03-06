module Time.TimeZone
    exposing
        ( TimeZone
        , name
        , abbreviation
        , offset
        , offsetString
        , setName
        , unpack
        )

{-| This module defines a representations for Timezone information.


# TimeZone values

@docs TimeZone, name, abbreviation, offset, offsetString


# Manipulating TimeZones

@docs setName


# Constructing TimeZones

@docs unpack

-}

import Char
import Debug
    exposing
        ( log
        )
import Parser
    exposing
        ( (|.)
        , (|=)
        , Count(..)
        , Error
        , Parser
        , andThen
        , delayedCommit
        , end
        , fail
        , ignore
        , inContext
        , keep
        , map
        , oneOf
        , oneOrMore
        , run
        , succeed
        , zeroOrMore
        )
import Time exposing (Time)
import Time.Internal exposing (..)


{-| TimeZone represents the opaque type of timezone values. These are
generally loaded from an external source via `unpack`.

See also <http://momentjs.com/timezone/docs/#/data-formats/packed-format/>.

-}
type TimeZone
    = TimeZone
        { name : String
        , spans : List Span
        }


{-| Spans represent variations within a TimeZone. A Time has an
associated Span if `.from <= t < .until`.

`offset` is the Span's UTC offset in milliseconds.

-}
type alias Span =
    { from : Time
    , until : Time
    , abbreviation : String
    , offset : Int
    }


{-| Given an arbitrary Time and a TimeZone, abbreviation returns the
TimeZone's abbreviation at that Time.
-}
abbreviation : Time -> TimeZone -> String
abbreviation time (TimeZone { spans }) =
    find time spans |> .abbreviation


{-| Given an arbitrary Time and a TimeZone, offset returns the
TimeZone's UTC offset in milliseconds at that Time.
-}
offset : Time -> TimeZone -> Int
offset time (TimeZone { spans }) =
    find time spans |> .offset


{-| Given an arbitrary Time and TimeZone, offsetString returns an
ISO8601-formatted UTC offset for at that Time.
-}
offsetString : Time -> TimeZone -> String
offsetString time timeZone =
    let
        utcOffset =
            offset time timeZone // minuteMs

        hours =
            abs utcOffset // 60

        minutes =
            abs utcOffset % 60

        string =
            padded hours ++ ":" ++ padded minutes
    in
        if utcOffset <= 0 then
            "+" ++ string
        else
            "-" ++ string


find : Time -> List Span -> Span
find time spans =
    let
        go xs =
            case xs of
                [] ->
                    Debug.crash "find: invalid span list"

                x :: xs ->
                    if time >= x.from && time < x.until then
                        x
                    else
                        go xs
    in
        go spans


{-| setName updates a TimeZone's name.
-}
setName : String -> TimeZone -> TimeZone
setName name (TimeZone tz) =
    TimeZone { tz | name = name }


{-| name returns a TimeZone's name.
-}
name : TimeZone -> String
name (TimeZone { name }) =
    name


{-| unpackNew decodes a packed zone data object into a TimeZone value.

See also <http://momentjs.com/timezone/docs/#/data-formats/packed-format/>

-}
unpack : String -> Result Error TimeZone
unpack data =
    run packedTimeZone data


{-| packedTimeZoneNew parses a zone data string into a TimeZone, validating that
the data format invariants hold.
-}
packedTimeZone : Parser TimeZone
packedTimeZone =
    let
        decode =
            (succeed PackedTimeZone
                |= parseName
                |. pipe
                |= parseAbbrevs
                |. pipe
                |= parseOffsets
                |. pipe
                |= parseIndices
                |. pipe
                |= parseDiffs
            )

        validate data =
            let
                abbrevs =
                    List.length data.abbrevs

                offsets =
                    List.length data.offsets

                maxIndex =
                    List.maximum data.indices
                        |> Maybe.withDefault 0
            in
                if abbrevs /= offsets then
                    fail "abbrevs and offsets have different lengths"
                else if maxIndex >= abbrevs then
                    fail "highest index is longer than both abbrevs and offsets"
                else
                    succeed data

        span times data i idx =
            { from = times !! i
            , until = times !! (i + 1)
            , abbreviation = data.abbrevs !! idx
            , offset = round (data.offsets !! idx * minuteMs)
            }

        convert data =
            let
                times =
                    if not <| List.isEmpty data.diffs then
                        List.scanl (+) (data.diffs !! 0) (List.drop 1 data.diffs)
                    else
                        []

                -- surround times with - and +infinity
                paddedTimes =
                    [ -1 / 0 ] ++ times ++ [ 1 / 0 ]
            in
                TimeZone
                    { name = data.name
                    , spans = List.indexedMap (span paddedTimes data) data.indices
                    }
    in
        decode
            |> andThen validate
            |> map convert


type alias PackedTimeZone =
    { name : String
    , abbrevs : List String
    , offsets : List Float
    , indices : List Int
    , diffs : List Float
    }


{-| Parse the name of the timezone
-}
parseName : Parser String
parseName =
    inContext "name" <|
        succeed identity
            |= keep oneOrMore ((/=) '|')


{-| Parse the first abbrev and then use `abbrevsHelp` to find
the remaining ones.
-}
parseAbbrevs : Parser (List String)
parseAbbrevs =
    let
        abbrev : Parser String
        abbrev =
            keep oneOrMore (\c -> c /= ' ' && c /= '|')

        helper : List String -> Parser (List String)
        helper revTerms =
            oneOf
                [ next
                    |> andThen (\s -> helper (s :: revTerms))
                , succeed (List.reverse revTerms)
                ]

        next : Parser String
        next =
            succeed identity
                |. parseSpace
                |= abbrev
    in
        inContext "abbrevs" <|
            succeed identity
                |= andThen (\s -> helper [ s ]) abbrev


parseOffsets : Parser (List Float)
parseOffsets =
    let
        offset : Parser Float
        offset =
            (succeed (,,)
                |= parseSign
                |= parseWhole
                |= parseFrac
            )
                |> andThen convertBase60

        convertBase60 : ( Int, String, String ) -> Parser Float
        convertBase60 ( sign, whole, frac ) =
            if whole == "" && frac == "" then
                fail "expected an alphanumeric character or ."
            else
                succeed <| unsafeBase60 sign whole frac

        convertFrac : String -> Parser String
        convertFrac frac =
            succeed frac

        helper : List Float -> Parser (List Float)
        helper revTerms =
            oneOf
                [ next
                    |> andThen (\f -> helper (f :: revTerms))
                , succeed (List.reverse revTerms)
                ]

        next : Parser Float
        next =
            succeed identity
                |. parseSpace
                |= offset
    in
        inContext "offsets" <|
            succeed identity
                |= andThen (\f -> helper [ f ]) offset


parseIndices : Parser (List Int)
parseIndices =
    let
        helper : List Int -> Parser (List Int)
        helper revTerms =
            oneOf
                [ next
                    |> andThen (\i -> helper (i :: revTerms))
                , succeed (List.reverse revTerms)
                ]

        next : Parser Int
        next =
            succeed identity
                |= index

        index : Parser Int
        index =
            keep (Exactly 1) (\c -> Char.isDigit c)
                |> andThen convertDecimal

        convertDecimal : String -> Parser Int
        convertDecimal digit =
            case String.toInt digit of
                Err msg ->
                    fail msg

                Ok value ->
                    succeed value
    in
        inContext "indices" <|
            succeed identity
                |= andThen (\i -> helper [ i ]) index


parseDiffs : Parser (List Float)
parseDiffs =
    let
        emptyDiffs : Parser (List Float)
        emptyDiffs =
            (succeed identity
                |. pipe
            )
                |> andThen (\_ -> succeed [])

        diffsEnd : Parser (List Float)
        diffsEnd =
            (succeed identity
                |. end
            )
                |> andThen (\_ -> succeed [])

        helper : List Float -> Parser (List Float)
        helper revTerms =
            oneOf
                [ next
                    |> andThen (\f -> helper (f :: revTerms))
                , succeed (List.reverse revTerms)
                ]

        next : Parser Float
        next =
            succeed identity
                |. parseSpace
                |= diff

        diff : Parser Float
        diff =
            (succeed (,,)
                |= parseSign
                |= parseWhole
                |= parseFrac
            )
                |> andThen convertBase60Times60000

        convertBase60Times60000 : ( Int, String, String ) -> Parser Float
        convertBase60Times60000 ( sign, whole, frac ) =
            if whole == "" && frac == "" then
                fail "expected an alphanumeric character or ."
            else
                succeed <| (*) 60000 (unsafeBase60 sign whole frac)
    in
        inContext "diffs" <|
            oneOf
                [ emptyDiffs
                , diffsEnd
                , andThen (\f -> helper [ f ]) diff
                ]


pipe : Parser ()
pipe =
    ignore (Exactly 1) ((==) '|')


parseSpace : Parser ()
parseSpace =
    ignore (Exactly 1) ((==) ' ')


parseSign : Parser Int
parseSign =
    let
        minusOne : String -> Parser Int
        minusOne hyphen =
            succeed -1
    in
        oneOf
            [ keep (Exactly 1) (\c -> c == '-')
                |> andThen minusOne
            , succeed 1
            ]


parseWhole : Parser String
parseWhole =
    keep zeroOrMore (\c -> unsafeBase60Digit c)


parseFrac : Parser String
parseFrac =
    oneOf
        [ parseSuccessfulFrac
        , succeed ""
        ]


unsafeBase60Digit : Char -> Bool
unsafeBase60Digit c =
    Char.isDigit c || Char.isUpper c || Char.isLower c


parseSuccessfulFrac : Parser String
parseSuccessfulFrac =
    (succeed identity
        |. ignore (Exactly 1) (\c -> c == '.')
        |= keep oneOrMore (\c -> unsafeBase60Digit c)
    )


unsafeBase60 : Int -> String -> String -> Float
unsafeBase60 sign whole frac =
    let
        toNum c =
            let
                n =
                    Char.toCode c |> toFloat
            in
                if n > 96 then
                    n - 87
                else if n > 64 then
                    n - 29
                else
                    n - 48

        toWhole cs acc =
            case cs of
                [] ->
                    acc

                c :: cs ->
                    toWhole cs (60 * acc + toNum c)

        toFrac cs mul acc =
            let
                mul_ =
                    mul / 60
            in
                case cs of
                    [] ->
                        acc

                    c :: cs ->
                        toFrac cs mul_ (acc + mul_ * toNum c)
    in
        toWhole (String.toList whole) 0
            |> toFrac (String.toList frac) 1
            |> ((*) (toFloat sign))


(!!) : List a -> Int -> a
(!!) xs i =
    case List.head (List.drop i xs) of
        Nothing ->
            Debug.crash ("index too large: xs=" ++ toString xs ++ " i=" ++ toString i)

        Just x ->
            x
