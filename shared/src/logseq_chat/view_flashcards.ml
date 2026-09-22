open Lui_elements

let flashcard_answer_row answer_source : t =
  let answer = Signal.sample answer_source in
  text
    ~value_signal:(reactive View_base.flashcard_answer_text answer_source)
    ~accessibility_identifier:
      (View_base.flashcard_answer_identifier answer)
    []

(* Flashcard controls use shared button typography and alignment semantics. *)

let flashcard_rating_button rating title foreground background send : t =
  button ~variant:"ghost" ~style_class:"semibold" ~grow:1.0 ~min_height:50
    ~text_alignment:"center" ~foreground ~background ~corner_radius:14
    ~accessibility_identifier:("button.flashcard.rating." ^ rating)
    ~on_press:(press send (Model.ReviewFlashcard rating))
    [ text ~value:title [] ]

let flashcard_review_content model_source send : t =
  column ~accessibility_identifier:"layout.flashcards.review" ~grow:1.0
    ~gap:0 ~padding_horizontal:20
    [
      box ~height:18 ~accessibility_identifier:"spacer.flashcards.top" [];
      column ~accessibility_identifier:"layout.flashcards.review-content"
        ~grow:1.0 ~gap:18
        [
          row ~accessibility_identifier:"row.flashcards.status"
            [
              text ~style_class:"footnote" ~foreground:"muted-foreground"
                ~value:"Due now" [];
              spacer ~grow:1.0 [];
              text ~style_class:"footnote" ~foreground:"muted-foreground"
                ~value_signal:
                  (reactive View_base.flashcard_remaining_label
                     model_source)
                [];
            ];
          scroll ~grow:1.0
            [
              column ~accessibility_identifier:"card.flashcard.question"
                ~gap:18 ~padding:22 ~background:"surface" ~corner_radius:18
                [
                  text ~style_class:"title2 semibold"
                    ~value_signal:
                      (reactive View_base.flashcard_question model_source)
                    ~accessibility_identifier:"flashcard.question" [];
                  if_
                    ~test:
                      (Signal.map View_base.flashcard_answer_rows_visible_
                         model_source)
                    (column ~gap:18
                       [
                         separator
                           ~accessibility_identifier:
                             "flashcard.answer-divider" [];
                         column ~gap:12
                           [
                             keyed
                               ~source:
                                 (Signal.map
                                    View_base
                                    .visible_flashcard_answer_rows
                                    model_source)
                               ~key:View_base.flashcard_answer_identifier
                               ~compare:compare
                               ~mount:flashcard_answer_row;
                           ];
                       ]);
                ];
            ];
          if_
            ~test:(Signal.map View_base.flashcard_show_cloze_ model_source)
            (row
               [
                 button ~variant:"ghost" ~style_class:"semibold" ~grow:1.0
                   ~min_height:50 ~text_alignment:"center"
                   ~foreground:"white" ~background:"primary"
                   ~corner_radius:14
                   ~accessibility_identifier:"button.flashcard.show-cloze"
                   ~on_press:(press send Model.RevealFlashcardCloze)
                   [ text ~value:"Show cloze" [] ];
               ]);
          if_
            ~test:(Signal.map View_base.flashcard_show_answer_ model_source)
            (row
               [
                 button ~variant:"ghost" ~style_class:"semibold" ~grow:1.0
                   ~min_height:50 ~text_alignment:"center"
                   ~foreground:"white" ~background:"primary"
                   ~corner_radius:14
                   ~accessibility_identifier:"button.flashcard.show-answer"
                   ~on_press:(press send Model.RevealFlashcardAnswer)
                   [ text ~value:"Show answer" [] ];
               ]);
          if_
            ~test:(Signal.map View_base.flashcard_show_ratings_ model_source)
            (column ~gap:10
               [
                 row ~gap:10
                   [
                     flashcard_rating_button "again" "Again" "red"
                       "flashcard-again-background" send;
                     flashcard_rating_button "hard" "Hard"
                       "warning-foreground" "flashcard-hard-background" send;
                   ];
                 row ~gap:10
                   [
                     flashcard_rating_button "good" "Good" "blue"
                       "flashcard-good-background" send;
                     flashcard_rating_button "easy" "Easy" "green"
                       "flashcard-easy-background" send;
                   ];
               ]);
        ];
      box ~height:24 ~accessibility_identifier:"spacer.flashcards.bottom"
        [];
    ]

let flashcard_screen model_source send : t =
  column ~accessibility_identifier:"screen.flashcards" ~grow:1.0 ~gap:0
    ~background:"background"
    [
      if_
        ~test:(Signal.map View_base.flashcards_empty_ model_source)
        (column ~accessibility_identifier:"layout.flashcards.empty"
           ~grow:1.0 ~main:"center" ~cross:"center" ~gap:10 ~padding:32
           [
             icon ~name:"app:flashcards" ~width:48 ~height:48
               ~foreground:"muted-foreground" [];
             heading ~level:3 ~value:"No cards due"
               ~accessibility_identifier:"flashcards.empty" [];
             text ~text_alignment:"center" ~foreground:"muted-foreground"
               ~value:"Tag any block with #Card to review it here." [];
           ]);
      if_
        ~test:(Signal.map View_base.flashcards_present_ model_source)
        (flashcard_review_content model_source send);
    ]
